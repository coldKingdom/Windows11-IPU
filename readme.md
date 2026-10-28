# Flytta den autentiserade datorn mellan OU

Exemplet använder klassisk ASP.NET på .NET Framework 4.8, IIS Windows Authentication och Windows PowerShell 5.1. Alla OU ska finnas i samma AD-domän. Ingen AD-modul behövs på klienten.

## Så fungerar det

1. Task Sequence kör PowerShell som SYSTEM på den domänanslutna datorn.
2. `Invoke-RestMethod -UseDefaultCredentials` autentiserar nätverksanropet med datorns konto, exempelvis `CONTOSO\PC001$`.
3. IIS ger ASP.NET anroparens Windows-identitet. Handlern använder dess SID för att hitta just det datorobjektet.
4. Apppoolens domänkonto utför AD-flytten. Impersonation är avstängt. Klientens identitet behöver därför inte delegeras till AD.

## 1. Förbered IIS

- Använd en domänansluten IIS-server med .NET Framework 4.8 samt IIS-rolltjänsterna ASP.NET 4.x och Windows Authentication installerade.
- Skapa en separat IIS-applikation, exempelvis `/OUmove`.
- Kopiera endast `MoveComputer.ashx` och `web.config` till applikationens fysiska katalog. PowerShell-filen körs på klienterna.
- Använd en separat apppool med **.NET CLR v4.0** och **Integrated** pipeline.
- Ställ apppoolens Identity till domänkontot som ska utföra flyttarna. Ett befintligt korrekt konfigurerat gMSA går också bra.
- Ge kontot läs-/köråtkomst till applikationsfilerna och de AD-rättigheter som beskrivs nedan. Klientkonton ska inte ha skrivrättigheter till filerna.
- Skapa loggkatalogen enligt avsnittet om serverloggning nedan och ge apppoolkontot skrivrättigheter där. Utan fungerande loggning stoppas flyttanropet med HTTP 503.
- I IIS-applikationens Authentication: **Windows Authentication = Enabled**, **Anonymous Authentication = Disabled**, **ASP.NET Impersonation = Disabled**. `web.config` sätter också `impersonate="false"`.
- Använd HTTPS. Skriptet accepterar alla servercertifikat för detta anrop, se nedan.
- Börja med IIS-serverns riktiga FQDN i URL:en och standardinställningarna för Windows Authentication. Egna DNS-alias kan kräva separat HTTP-SPN-konfiguration. Ändra inte SPN eller `useAppPoolCredentials` på chans.

Windows-autentiseringen ställs i IIS-gränssnittet för att undvika problem med låsta konfigurationssektioner i web.config.

## 2. Delegera AD-rättigheter

Begränsa apppoolkontots rättigheter till berörda OU och datorobjekt:

- Läsa/lista datorobjekt och relevanta attribut i käll- och mål-OU.
- **Delete Computer objects** på käll-OU, alternativt motsvarande Delete-rättighet på berörda datorobjekt.
- **Create Computer objects** på varje tillåtet mål-OU.

Det är AD:s rättighetsnamn för att flytta ut respektive in ett objekt; koden använder MoveTo och återskapar inte datorkontot. Den inbyggda delegeringsguidens uppgift att bara ansluta datorer till domänen räcker inte nödvändigtvis för en flytt.

Kontrollera eventuella explicita Deny-regler och skydd mot oavsiktlig borttagning om en flytt ger Access denied. Koden ändrar inga sådana skydd. Kontot behöver inte vara Domain Admin.

## 3. Anpassa filerna

I `MoveComputer.ashx`:

- `Dc`: en skrivbar domänkontrollants FQDN, exempelvis `dc01.contoso.local`.
- `SourceOu`: OU där datorerna får hämtas.
- `AllowedTargets`: fullständiga DN för de mål-OU som får väljas.

I `web.config`:

- `OUmove.LogDirectory`: absolut sökväg till serverns loggkatalog. Standardvärdet är `C:\ProgramData\OUmove\Logs`.

I `MoveComputer.ps1`:

- `$uri`: applikationens HTTPS-adress.
- `$targetOu`: det fullständiga mål-DN som detta skript ska begära. Det måste finnas i serverns `AllowedTargets`.
- `$maxAttempts`: maximalt antal anrop inklusive det första, standard 3.
- `$defaultRetryDelaySeconds`: väntetid om `Retry-After` saknas eller är ogiltigt, standard 10 sekunder.
- `$maxRetryDelaySeconds`: längsta accepterade väntetid mellan anrop, standard 60 sekunder. Vid längre begärd väntan avbryts körningen i stället för att återförsöka för tidigt.

### Godkänn alla servercertifikat

Skriptet anropar den angivna funktionen `Set-CertificateValidationCallback` före `Invoke-RestMethod`. Funktionen använder den Base64-kodade C#-klassen `ServerCertificateValidationCallback` och lägger bara till typen om den saknas. En skriptflagga förhindrar upprepad aktivering.

När ingen global callback redan är registrerad installeras en callback som accepterar alla servercertifikat. Ingen export, import eller konfiguration av fingeravtryck behövs. Även självsignerade och utgångna certifikat samt certifikat med fel namn accepteras.

Detta innebär att TLS-certifikatet inte används för att verifiera serverns identitet, vilket möjliggör en mellanmansattack. HTTPS och Windows-autentiseringen används fortfarande.

Funktionen ändrar `ServicePointManager.ServerCertificateValidationCallback` globalt i PowerShell-processen och påverkar även andra HTTPS-anrop som använder den inställningen. Den ändrar inte klientens certifikatlager. Om en callback redan finns lämnas den kvar enligt funktionens `if (... == null)`; då styr den befintliga callbacken vilka certifikat som accepteras. HTTP-omdirigeringar följs inte. Skriptet är avsett för Windows PowerShell 5.1; PowerShell 7:s `Invoke-RestMethod` använder inte denna inställning.

Sökningen omfattar endast datorer direkt i angivet OU, inte under-OU. Alla LDAP-operationer använder samma DC för att undvika replikeringsfördröjning mellan själva sökningen och flytten. Efter en ny domänanslutning kan datorobjektet ändå behöva hinna replikeras till denna DC före anropet.

## 4. Lägg till i Task Sequence

Använd **Run PowerShell Script** efter domänanslutning, **Setup Windows and ConfigMgr** och omstart till fullständigt Windows. Lämna **Run this step as the following account** avmarkerat så att steget körs som SYSTEM. Anropet kräver fungerande domänkontakt och datorns domänidentitet; detta upplägg fungerar inte som motsvarande datorautentisering i WinPE.

Du kan klistra in PowerShell-koden direkt i steget eller distribuera filen i ett paket enligt era vanliga skript-/signeringsregler. För signerade skript med AllSigned används filen i ett paket.

Skriptet avslutar med 0 vid lyckad flytt eller om datorn redan ligger i det begärda mål-OU:t. HTTP-fel ger exitkod 1 och feltext i skriptets statusutdata och transcript. Låt steget stoppa vid fel om flytten är ett krav för fortsatt installation.

### Transcript och statusmeddelanden

Skriptet använder `Start-Transcript` och `Write-Host`. En ny loggfil skapas per körning med namnet `MoveComputer_yyyyMMdd_HHmmss_fff_PID.log`.

Loggkatalogen hämtas från Task Sequence-variabeln `_SMSTSLogPath` via `Microsoft.SMS.TSEnvironment`. Vid manuell körning utan tillgänglig TS-loggkatalog används `OUmove` under processens temporära katalog.

Loggen innehåller datornamn, lokalt körkonto, vald loggkatalog, URL, begärt mål-OU, aktivering av certifikatfunktionen, POST-anrop, serversvar, fel och exitkod. Det lokala kontot visas som SYSTEM när steget körs som SYSTEM; servern identifierar nätverksanropet med datorns domänkonto. Skriptet kan inte självt läsa serverns autentiserade identitet.

Vid HTTP 503 loggas också försöksnummer, referens-ID, felsvar och väntetid före nästa försök. Alla försök körs inom samma transcript och begär samma mål-OU.

`Stop-Transcript` körs i `finally` före `exit`. Även fel skrivs med `Write-Host` så att de kommer med i transkriberingen. Om loggningen inte kan startas avbryts körningen med exitkod 1 före webb-anropet. Transkriberingen skapar en separat textlogg; den skriver inte direkt i själva `smsts.log`.

## Kontrollera innan bred utrullning

Prova först med en testdator i käll-OU och kör anropet som SYSTEM. Bekräfta flytten mot samma DC. Kör sedan igen: svaret ska innehålla `ALREADY_IN_TARGET`. Testa också ett otillåtet mål och ett vanligt användarkonto; ingen dator ska då flyttas.

### Felsvar och upprepade anrop

Handlern läser och validerar formuläret inom sin felhantering. Den kräver POST med `application/x-www-form-urlencoded` och exakt ett `TargetOU`, som måste finnas i listan över godkända mål.

| HTTP | Resultat |
| --- | --- |
| 200 | `MOVED`, `ALREADY_IN_TARGET` eller `TARGET_VERIFIED`. |
| 400 | `INVALID_TARGET`, `INVALID_FORM` eller `INVALID_REQUEST`. |
| 401 | `AUTHENTICATION_REQUIRED`. IIS kan också neka anrop innan handlern körs. |
| 403 | `HTTPS_REQUIRED`, `CALLER_NOT_ALLOWED` eller `AD_ACCESS_DENIED`. Det senare gäller tjänstens AD-rättigheter. |
| 405 | `METHOD_NOT_ALLOWED`. |
| 413 | `INVALID_REQUEST` när ett motsvarande ASP.NET-fel når handlern. |
| 415 | `UNSUPPORTED_MEDIA_TYPE`. |
| 503 | `AD_UNAVAILABLE` vid identifierade timeout-/server-down-/busy-/unavailable-fel, eller `AUDIT_UNAVAILABLE` om loggningen inte fungerar före AD-operationen. |
| 500 | `INTERNAL_ERROR` för övriga oväntade fel. |

Alla handlersvar innehåller resultatkod och referens-ID i textsvaret. Samma ID finns i HTTP-headern `X-OUmove-RequestId`, serverloggen och ett tillägg till IIS-loggen. Råa undantagsdetaljer lämnas endast i serverloggen. Fel som stoppas av IIS/ASP.NET före handlern följer plattformens egna felsvar.

Om `MoveTo` eller `CommitChanges` ger fel söker handlern på nytt efter anroparens SID i begärt mål-OU på samma DC. Lyckat resultat (`TARGET_VERIFIED`) kräver även att objektets GUID är samma som före flyttförsöket. Ett annat GUID, utebliven träff eller misslyckad efterkontroll ger inte ett falskt lyckat svar. Efterkontrollen gör ett upprepat anrop eller ett samtidigt anrop till samma mål tåligare; den låser inte objektet mot andra administratörers ändringar.

HTTP 503 från handlern innehåller `Retry-After: 10`. PowerShell-skriptet gör högst tre försök totalt vid just HTTP 503, med samma mål varje gång. `Retry-After` läses som antal sekunder eller ett HTTP-datum. Saknat/ogiltigt värde ger tio sekunders väntan. Om begärd väntan överstiger `$maxRetryDelaySeconds` görs inget nytt försök. Efter ett lyckat anrop returneras exitkod 0; när försöken är slut returneras 1. Övriga HTTP-fel samt nätverks-/klienttimeout utan HTTP 503 stoppar direkt.

Varje HTTP-anrop har `TimeoutSec 90`. Med standardinställningarna kan tre anrop och två väntetider ta flera minuter; välj en tidsgräns för Task Sequence-steget som ger tillräckligt utrymme, exempelvis tio minuter. Vid timeout kan flytten redan ha genomförts. Ett nytt anrop ska därför begära samma mål. Felaktigt OU, otillräckliga rättigheter och andra konfigurationsfel behöver åtgärdas, inte bara upprepas.

### Beständig serverloggning

Skapa katalogen som anges av `OUmove.LogDirectory` på IIS-servern innan applikationen används. Katalogen ska ligga **utanför webbplatsens fysiska katalog**. Begränsa NTFS-behörigheterna till administratörer, SYSTEM och apppoolens domänkonto; ge apppoolkontot Modify för att skapa och skriva loggfiler. Klientkonton behöver ingen åtkomst. Katalogen skapas inte automatiskt av handlern.

Filerna heter `OUmove_yyyyMMdd_<applikationsinstans>.log` med datum i UTC. Varje applikationsinstans har ett eget filnamn för att undvika skrivkonflikter mellan IIS-processer eller vid återstart. Loggen är UTF-8 med tolv tabseparerade kolumner:

`UTC-tid, referens-ID, fas, HTTP-status, resultatkod, anropande konto, SID, dator-GUID, tillåtet käll-OU, ursprungligt dator-DN, begärt mål-OU, undantagsdetaljer`.

Radbrytningar, tabbar och backslash i fält är escapade; långa fält begränsas. GUID och ursprungligt DN fylls när källobjektet har hittats. Vid `ALREADY_IN_TARGET` kan det ursprungliga DN:t vara tomt eftersom ingen flytt behövdes.

Ett validerat anrop loggas som `accepted` före AD-operationen och sedan som `completed` med sitt resultat. `accepted` har status 0 och resultat `PENDING`; det är inte ett lyckat flyttresultat. Nekade/ogiltiga anrop får endast `completed` när loggningen fungerar. En ensam `accepted`-rad kan betyda att processen avbröts; kontrollera då faktisk AD-placering innan slutsatser dras.

Om den första loggskrivningen misslyckas görs ingen flytt. Om slutloggningen misslyckas efter en genomförd flytt behålls det lyckade svaret, men headern `X-OUmove-Audit: failed` och markören `OUmoveAuditFailed=<ID>` i IIS-loggen anger loggfelet. Den markören förutsätter fungerande IIS-loggning. Det är inte möjligt att göra AD-flytten och en filskrivning till en gemensam transaktion.

Planera gallring/insamling av loggfiler och övervaka ledigt diskutrymme. Filerna innehåller intern AD-information och ska inte publiceras eller exponeras som webbinnehåll.

Windows-autentiseringen styrker datorkontot. Den styrker inte att anropet kommer från just en SCCM Task Sequence: annan kod som kör som SYSTEM på samma dator kan göra samma begäran. Varje godkänd dator i käll-OU kan välja bland alla konfigurerade mål.

## Verifiering av exemplet

Handlerns C# har kompilerats med .NET Frameworks kompilator. PowerShell-skriptets syntax och web.config-filens XML har kontrollerats. Den aktuella funktionen har testats offline i Windows PowerShell 5.1: den installerar sin callback, accepterar samtliga kombinationer av TLS-certifikatfel, kan anropas upprepade gånger utan typkonflikt och lämnar en befintlig callback oförändrad. Transcript har också testats med simulerade TS-variabler och HTTP-anrop för lyckad flytt, redan korrekt placering och anropsfel: vald loggkatalog, logginnehåll, avslutad transkribering och exitkoder 0/1 har verifierats. IIS/TLS-anrop, autentisering och faktisk AD-flytt måste verifieras i er miljö; de har inte testats mot er server eller domän.

Den förbättrade handlern har även klarat 32 automatiska kontroller utan AD-/nätverksanrop: vanlig flytt, redan rätt placering, verifiering efter flyttfel, avvikande GUID, fel vid efterkontroll, HTTP-felkategorier, loggskrivning/escaping, ogiltiga och dubbla formulärvärden samt stopp före AD-operationen när loggningen saknas.

Återförsöken har verifierats i Windows PowerShell 5.1 med 13 simulerade scenarier: omedelbar framgång, framgång efter 503, framgång på tredje försöket, uttömt antal försök, stopp vid 400/403/500, timeout utan HTTP-svar, `Retry-After` som datum, ogiltig/saknad header, för lång begärd väntan och ett inbäddat WebException. Tester kontrollerar antal anrop, väntetider, oförändrat mål, referens-ID i loggen, avslutat transcript och exitkod. Inga verkliga väntetider, IIS-anrop eller AD-flyttar görs i dessa tester.

## Dokumentation

- [LocalSystem och datorns nätverksidentitet](https://learn.microsoft.com/en-us/windows/win32/ad/the-localsystem-account)
- [Windows Authentication i IIS](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/authentication/windowsauthentication/)
- [ASP.NET impersonation](https://learn.microsoft.com/en-us/iis/application-frameworks/scenario-build-an-aspnet-website-on-iis/configuring-step-4-configure-application-security)
- [DirectoryEntry.MoveTo](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.directoryentry.moveto?view=netframework-4.8)
- [Invoke-RestMethod i Windows PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod?view=powershell-5.1)
- [Task Sequence: Run PowerShell Script](https://learn.microsoft.com/en-us/intune/configmgr/osd/understand/task-sequence-steps#run-powershell-script)


