# Kerberos metadata for the native image

SQL Server with `authenticationScheme=JavaKerberos` goes through JAAS and the
GSS-API, which reach their implementations by name rather than by a compiled-in
reference. `native-image` cannot see those edges, so every one of them has to be
declared here or the native binary fails where the JVM succeeds.

`reflect-config.json`

- `sun.security.provider.ConfigFile` — the default JAAS `Configuration`, named by
  the `login.configuration.provider` security property and loaded with
  `Class.forName` from `Configuration.getConfiguration()`. mssql-jdbc calls that
  in `KerbAuthentication`'s static initializer, so without this entry a Kerberos
  connection dies before it opens a socket.
- `com.sun.security.auth.module.Krb5LoginModule` — the login module mssql-jdbc's
  default JAAS entry names; `LoginContext` instantiates it by name.
- `sun.security.jgss.SunProvider` and the two mechanism factories —
  `sun.security.jgss.ProviderList` looks up the Kerberos mechanism among the
  installed providers and instantiates the factory class the provider names.

`resource-config.json` — the message bundles the paths above read. JAAS formats
every login error through `sun.security.util.ResourcesMgr`, which names two
bundles; when either is missing, a login failure throws `MissingResourceException`
and the real Kerberos error never reaches the caller. The JDK renamed both
between 21 and 25:

    21                               25
    sun.security.util.Resources      sun.security.util.resources.security
    sun.security.util.AuthResources  sun.security.util.resources.auth

All four names are listed because the release binaries build on 21 while local
builds run on 25, and a name that does not resolve is ignored rather than fatal.
To re-check after a JDK bump, read the names out of the bytecode rather than
guessing:

    javap -c -p --module java.base sun.security.util.ResourcesMgr | grep 'String sun.security'

The mssql-jdbc bundle backs every `SQLServerException` message, so a real
Kerberos error reports itself instead of disappearing.

`native-image.properties` — reflection registration alone does not put SunJGSS in
`Security.getProviders()`, and the GSS-API only finds a mechanism through that
list, so the provider is also marked as used at build time.

`MacosKerberosFeature` (in `src/main/java`, registered from the pom's native
profile) covers what no JSON file can: on macOS the ticket lives in the system
credential store, which Java reaches through the JDK's `libosxkrb5` — a library
a native binary cannot `System.loadLibrary`, because nothing ships the dylib
next to it. The feature links GraalVM's static copy of that archive into the
image, classifies it as built in, and registers the types its C code constructs
through JNI. It is macOS-only; a Linux image never sees it.

To re-derive this list after a driver upgrade, run the tracing agent on a machine
that completes a real Kerberos login — some classes only load after a successful
one:

    java -agentlib:native-image-agent=config-merge-dir=src/main/resources/META-INF/native-image/com.dblite/dblite \
         -cp target/classes:<mssql-jdbc.jar> com.dblite.App <<<'SELECT SUSER_SNAME()'
