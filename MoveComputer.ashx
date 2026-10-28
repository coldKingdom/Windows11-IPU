<%@ WebHandler Language="C#" Class="MoveComputer" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.DirectoryServices;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Web;

public class MoveComputer : IHttpHandler
{
    // ÄNDRA: Samma skrivbara DC och AD-domän för alla OU.
    private const string Dc = "dc01.contoso.local";
    private const string SourceOu = "OU=Staging,DC=contoso,DC=local";
    private static readonly HashSet<string> AllowedTargets =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "OU=Workstations,DC=contoso,DC=local",
            "OU=Kiosks,DC=contoso,DC=local"
        };
    private static readonly object LogLock = new object();
    // Separata filer per applikationsinstans undviker konflikt vid IIS-recycle.
    private static readonly string LogInstance = Guid.NewGuid().ToString("N");

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        AuditRecord audit = new AuditRecord();
        HandlerResult result;
        context.Response.ContentType = "text/plain; charset=utf-8";
        context.Response.TrySkipIisCustomErrors = true;
        context.Response.SuppressFormsAuthenticationRedirect = true;
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);
        context.Response.Cache.SetNoStore();
        context.Response.AddHeader("X-OUmove-RequestId", audit.RequestId);

        try
        {
            result = ProcessCore(context, audit);
        }
        catch (Exception ex)
        {
            audit.Error = ex.ToString();
            result = ClassifyError(ex);
        }

        audit.Status = result.Status;
        audit.Outcome = result.Code;
        try
        {
            WriteAudit(ConfigurationManager.AppSettings["OUmove.LogDirectory"], audit, "completed");
        }
        catch (Exception logError)
        {
            // Ett loggfel efter genomförd flytt ändrar inte resultatet av flytten.
            context.Response.AddHeader("X-OUmove-Audit", "failed");
            AppendIisLog(context, " OUmoveAuditFailed=" + audit.RequestId);
            try { System.Diagnostics.Trace.TraceError("OUmove audit {0}: {1}", audit.RequestId, logError); }
            catch { /* En felande Trace-listener får inte ändra flyttresultatet. */ }
        }

        AppendIisLog(context, " OUmove=" + audit.RequestId + ":" + result.Code);
        if (result.Status == 503)
            context.Response.AddHeader("Retry-After", "10");
        context.Response.StatusCode = result.Status;
        context.Response.Write(result.Code + ": " + result.Message + " Reference: " + audit.RequestId);
    }

    private static HandlerResult ProcessCore(HttpContext context, AuditRecord audit)
    {
        WindowsIdentity identity = context.User == null ? null :
            context.User.Identity as WindowsIdentity;
        if (identity != null && identity.IsAuthenticated && identity.User != null)
        {
            audit.Caller = identity.Name;
            audit.Sid = identity.User.Value;
        }

        if (!context.Request.IsSecureConnection)
            return Result(403, "HTTPS_REQUIRED", "HTTPS required.");
        if (context.Request.HttpMethod != "POST")
        {
            context.Response.AddHeader("Allow", "POST");
            return Result(405, "METHOD_NOT_ALLOWED", "POST required.");
        }
        if (String.IsNullOrEmpty(audit.Sid))
            return Result(401, "AUTHENTICATION_REQUIRED", "Windows authentication required.");

        string mediaType = (context.Request.ContentType ?? "").Split(';')[0].Trim();
        if (!String.Equals(mediaType, "application/x-www-form-urlencoded", StringComparison.OrdinalIgnoreCase))
            return Result(415, "UNSUPPORTED_MEDIA_TYPE", "A URL-encoded form is required.");

        // Formläsning och request validation ingår i den samlade felhanteringen.
        string[] targets = context.Request.Form.GetValues("TargetOU");
        if (targets == null || targets.Length != 1 || String.IsNullOrWhiteSpace(targets[0]))
            return Result(400, "INVALID_TARGET", "Exactly one TargetOU is required.");
        audit.Target = targets[0].Trim();
        if (!AllowedTargets.Contains(audit.Target))
            return Result(400, "INVALID_TARGET", "TargetOU is not allowed.");

        // Om loggen inte kan skrivas stoppas anropet före någon AD-flytt.
        try
        {
            WriteAudit(ConfigurationManager.AppSettings["OUmove.LogDirectory"], audit, "accepted");
        }
        catch (Exception ex)
        {
            throw new AuditUnavailableException(ex);
        }

        byte[] sid = new byte[identity.User.BinaryLength];
        identity.User.GetBinaryForm(sid, 0);
        StringBuilder escapedSid = new StringBuilder();
        foreach (byte b in sid)
            escapedSid.Append('\\').Append(b.ToString("X2"));
        string filter = "(&(objectCategory=computer)(objectSid=" + escapedSid +
            ")(userAccountControl:1.2.840.113556.1.4.803:=4096))";

        using (DirectoryEntry source = OpenOu(SourceOu))
        using (DirectoryEntry target = OpenOu(audit.Target))
        {
            DirectoryEntry computer = null;
            try
            {
                MoveOutcome outcome = ResolveMove(
                    delegate
                    {
                        computer = FindComputer(source, filter);
                        if (computer == null) return null;
                        audit.ComputerGuid = computer.Guid.ToString("D");
                        audit.SourceDn = Convert.ToString(computer.Properties["distinguishedName"].Value);
                        return (Guid?)computer.Guid;
                    },
                    delegate
                    {
                        // Ny sökning på samma DC, samma SID och begärt mål-OU.
                        using (DirectoryEntry existing = FindComputer(target, filter))
                        {
                            if (existing == null) return null;
                            if (String.IsNullOrEmpty(audit.ComputerGuid))
                                audit.ComputerGuid = existing.Guid.ToString("D");
                            return (Guid?)existing.Guid;
                        }
                    },
                    delegate
                    {
                        computer.MoveTo(target);
                        computer.CommitChanges();
                    },
                    delegate(Exception ex) { audit.Error = ex.ToString(); });

                if (outcome == MoveOutcome.AlreadyInTarget)
                    return Result(200, "ALREADY_IN_TARGET", "Already in target OU.");
                if (outcome == MoveOutcome.VerifiedAfterError)
                    return Result(200, "TARGET_VERIFIED", "Computer confirmed in target OU after a move error.");
                return Result(200, "MOVED", "Computer moved.");
            }
            finally
            {
                if (computer != null) computer.Dispose();
            }
        }
    }

    // Fristående beslutslogik kan testas utan AD eller nätverksanrop.
    internal static MoveOutcome ResolveMove(Func<Guid?> findSource, Func<Guid?> findTarget,
        Action move, Action<Exception> recordMoveError)
    {
        Guid? original = findSource();
        if (!original.HasValue)
        {
            if (findTarget().HasValue) return MoveOutcome.AlreadyInTarget;
            throw new CallerNotAllowedException();
        }
        try { move(); }
        catch (Exception moveError)
        {
            recordMoveError(moveError);
            try
            {
                Guid? current = findTarget();
                if (current.HasValue && current.Value == original.Value)
                    return MoveOutcome.VerifiedAfterError;
            }
            catch (Exception verificationError)
            {
                // Bevara ursprungligt fel om efterkontrollen också misslyckas.
                recordMoveError(new AggregateException("Move and target verification failed.", moveError, verificationError));
            }
            throw;
        }
        return MoveOutcome.Moved;
    }

    internal static HandlerResult ClassifyError(Exception ex)
    {
        if (ex is AuditUnavailableException)
            return Result(503, "AUDIT_UNAVAILABLE", "Audit logging unavailable. No move was attempted.");
        if (ex is CallerNotAllowedException)
            return Result(403, "CALLER_NOT_ALLOWED", "Caller is not a workstation in the permitted source or target OU.");
        if (ex is HttpRequestValidationException)
            return Result(400, "INVALID_FORM", "Invalid form data.");
        HttpException httpError = ex as HttpException;
        if (httpError != null && (httpError.GetHttpCode() == 400 || httpError.GetHttpCode() == 413))
            return Result(httpError.GetHttpCode(), "INVALID_REQUEST", "Invalid request.");
        COMException directoryError = ex as COMException;
        if (ex is UnauthorizedAccessException || (directoryError != null &&
            (directoryError.ErrorCode == unchecked((int)0x80070005) ||
             directoryError.ErrorCode == unchecked((int)0x80072098))))
            return Result(403, "AD_ACCESS_DENIED", "AD operation not permitted. Check service account permissions.");
        if (ex is TimeoutException || (directoryError != null &&
            (directoryError.ErrorCode == unchecked((int)0x8007203A) ||
             directoryError.ErrorCode == unchecked((int)0x8007200E) ||
             directoryError.ErrorCode == unchecked((int)0x8007200F) ||
             directoryError.ErrorCode == unchecked((int)0x80072022))))
            return Result(503, "AD_UNAVAILABLE", "AD temporarily unavailable. Move outcome may be unknown; retry the same target.");
        return Result(500, "INTERNAL_ERROR", "OU move failed. See the server log using the reference ID.");
    }

    internal static void WriteAudit(string directory, AuditRecord audit, string phase)
    {
        if (String.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory))
            throw new ConfigurationErrorsException("OUmove.LogDirectory must be an absolute directory path.");
        // Katalog och ACL ska skapas av administratör, utanför webbplatsen.
        string file = Path.Combine(directory, "OUmove_" + DateTime.UtcNow.ToString("yyyyMMdd", CultureInfo.InvariantCulture) +
            "_" + LogInstance + ".log");
        string line = String.Join("\t", new string[] {
            DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture), audit.RequestId,
            LogField(phase), audit.Status.ToString(CultureInfo.InvariantCulture),
            LogField(audit.Outcome), LogField(audit.Caller), LogField(audit.Sid),
            LogField(audit.ComputerGuid), LogField(SourceOu), LogField(audit.SourceDn),
            LogField(audit.Target), LogField(audit.Error)
        });
        lock (LogLock)
        {
            using (FileStream stream = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.Read))
            using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false)))
                writer.WriteLine(line);
        }
    }

    private static string LogField(string value)
    {
        value = value ?? "";
        if (value.Length > 16384) value = value.Substring(0, 16384) + "[truncated]";
        return value.Replace("\\", "\\\\").Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
    }

    private static DirectoryEntry OpenOu(string dn)
    {
        // Inga klientcredentials: apppoolens konto används.
        return new DirectoryEntry("LDAP://" + Dc + "/" + dn, null, null,
            AuthenticationTypes.Secure | AuthenticationTypes.Signing |
            AuthenticationTypes.Sealing | AuthenticationTypes.ServerBind);
    }

    private static DirectoryEntry FindComputer(DirectoryEntry ou, string filter)
    {
        using (DirectorySearcher search = new DirectorySearcher(ou))
        {
            search.SearchScope = SearchScope.OneLevel;
            search.Filter = filter;
            search.SizeLimit = 1;
            search.ClientTimeout = TimeSpan.FromSeconds(20);
            search.ServerTimeLimit = TimeSpan.FromSeconds(20);
            SearchResult result = search.FindOne();
            return result == null ? null : result.GetDirectoryEntry();
        }
    }

    private static void AppendIisLog(HttpContext context, string message)
    {
        try { context.Response.AppendToLog(message); }
        catch { /* IIS-loggfel får inte ändra ett genomfört flyttresultat. */ }
    }

    private static HandlerResult Result(int status, string code, string message)
    { return new HandlerResult { Status = status, Code = code, Message = message }; }

    internal enum MoveOutcome { Moved, AlreadyInTarget, VerifiedAfterError }
    internal class HandlerResult { public int Status; public string Code; public string Message; }
    internal class CallerNotAllowedException : Exception { }
    internal class AuditUnavailableException : Exception
    { public AuditUnavailableException(Exception inner) : base("Audit logging unavailable.", inner) { } }
    internal class AuditRecord
    {
        public string RequestId = Guid.NewGuid().ToString("N");
        public string Caller, Sid, ComputerGuid, SourceDn, Target, Error;
        public int Status;
        public string Outcome = "PENDING";
    }
}
