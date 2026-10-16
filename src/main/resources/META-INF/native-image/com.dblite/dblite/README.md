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

`resource-config.json` — the message bundles the paths above read. The two JDK
bundles carry JAAS's own messages (a login failure throws `MissingResourceException`
without them); the mssql-jdbc bundle backs every `SQLServerException` message, so
a real Kerberos error reports itself instead of disappearing.

`native-image.properties` — reflection registration alone does not put SunJGSS in
`Security.getProviders()`, and the GSS-API only finds a mechanism through that
list, so the provider is also marked as used at build time.

To re-derive this list after a driver upgrade, run the tracing agent on a machine
that completes a real Kerberos login — some classes only load after a successful
one:

    java -agentlib:native-image-agent=config-merge-dir=src/main/resources/META-INF/native-image/com.dblite/dblite \
         -cp target/classes:<mssql-jdbc.jar> com.dblite.App <<<'SELECT SUSER_SNAME()'
