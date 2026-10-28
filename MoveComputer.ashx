                return Result(200, "MOVED", "Computer moved.");
            }
            finally
            {
                if (computer != null) computer.Dispose();
            }
        }
    }

    // Fristaende beslutslogik kan testas utan AD eller natverksanrop.
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
                // Bevara ursprungligt fel om efterkontrollen ocksa misslyckas.
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
        // Katalog och ACL ska skapas av administrator, utanfor webbplatsen.
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
        // Inga klientcredentials: apppoolens konto anvands.
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
        catch { /* IIS-loggfel far inte andra ett genomfort flyttresultat. */ }
    }

    private static HandlerResult Result(int status, string code, string message)
    { return new HandlerResult { Status = status, Code = code, Message = message }; }

    internal enum MoveOutcome { Moved, AlreadyInTarget, VerifiedAfterError }
    internal class HandlerResult { public int Status; public string Code; public string Message; }
    internal class CallerNotAllowedException : Exception { }
    internal class AuditUnavailableException : Exception
