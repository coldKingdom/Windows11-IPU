<%@ WebHandler Language="C#" Class="MoveComputer" %>

using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.Security.Principal;
using System.Text;
using System.Web;

public class MoveComputer : IHttpHandler
{
    // ANDRA: Samma skrivbara DC och samma AD-doman for alla OU.
    private const string Dc = "dc01.contoso.local";
    private const string SourceOu = "OU=Staging,DC=contoso,DC=local";
    private static readonly HashSet<string> AllowedTargets =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "OU=Workstations,DC=contoso,DC=local",
            "OU=Kiosks,DC=contoso,DC=local"
        };

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "text/plain; charset=utf-8";
        context.Response.TrySkipIisCustomErrors = true;
        context.Response.Cache.SetCacheability(HttpCacheability.NoCache);
        context.Response.Cache.SetNoStore();

        if (!context.Request.IsSecureConnection)
        { Reply(context, 403, "HTTPS required."); return; }

        if (context.Request.HttpMethod != "POST")
        {
            context.Response.AddHeader("Allow", "POST");
            Reply(context, 405, "POST required."); return;
        }

        WindowsIdentity identity = context.User == null ? null :
            context.User.Identity as WindowsIdentity;
        if (identity == null || !identity.IsAuthenticated || identity.User == null)
        { Reply(context, 401, "Windows authentication required."); return; }

        string targetOu = context.Request.Form["TargetOU"];
        if (String.IsNullOrWhiteSpace(targetOu) || !AllowedTargets.Contains(targetOu))
        { Reply(context, 400, "TargetOU is not allowed."); return; }

        try
        {
            // Anroparens SID kommer fran IIS, aldrig fran formularet.
            byte[] sid = new byte[identity.User.BinaryLength];
            identity.User.GetBinaryForm(sid, 0);
            StringBuilder escapedSid = new StringBuilder();
            foreach (byte b in sid)
                escapedSid.Append('\\').Append(b.ToString("X2"));

            // Krav pa datorobjekt och WORKSTATION_TRUST_ACCOUNT.
            // Ett anvandarkonto med namn som slutar pa $ accepteras inte.
            string filter = "(&(objectCategory=computer)(objectSid=" + escapedSid +
                ")(userAccountControl:1.2.840.113556.1.4.803:=4096))";

            using (DirectoryEntry source = OpenOu(SourceOu))
            using (DirectoryEntry target = OpenOu(targetOu))
            using (DirectoryEntry computer = FindComputer(source, filter))
            {
                if (computer == null)
                {
                    // Gor ett upprepat anrop till samma mal ofarligt.
                    using (DirectoryEntry existing = FindComputer(target, filter))
                    {
                        if (existing != null)
                        { Reply(context, 200, "Already in target OU."); return; }
                    }
                    Reply(context, 403, "Caller is not a workstation in the permitted source OU.");
                    return;
                }

                computer.MoveTo(target);
                computer.CommitChanges();
                Reply(context, 200, "Computer moved.");
            }
        }
        catch (Exception ex)
        {
            string errorId = Guid.NewGuid().ToString("N");
            // Konfigurera en Trace-listener pa servern for detaljerad fellogg.
            System.Diagnostics.Trace.TraceError("OU move {0}: {1}", errorId, ex);
            context.Response.AppendToLog(" OUmoveError=" + errorId);
            Reply(context, 500, "OU move failed. Reference: " + errorId);
        }
    }

    private static DirectoryEntry OpenOu(string dn)
    {
        // Inga klientcredentials: anvander apppoolens konto.
        return new DirectoryEntry("LDAP://" + Dc + "/" + dn, null, null,
            AuthenticationTypes.Secure | AuthenticationTypes.Signing |
            AuthenticationTypes.Sealing | AuthenticationTypes.ServerBind);
    }

    private static DirectoryEntry FindComputer(DirectoryEntry ou, string filter)
    {
        using (DirectorySearcher search = new DirectorySearcher(ou))
        {
            // Endast direkt i angivet OU, inte dess under-OU.
            search.SearchScope = SearchScope.OneLevel;
            search.Filter = filter;
            search.SizeLimit = 1;
            search.ClientTimeout = TimeSpan.FromSeconds(20);
            search.ServerTimeLimit = TimeSpan.FromSeconds(20);
            SearchResult result = search.FindOne();
            return result == null ? null : result.GetDirectoryEntry();
        }
    }

    private static void Reply(HttpContext context, int status, string message)
    {
        context.Response.StatusCode = status;
        context.Response.Write(message);
    }
}
