package com.dblite.nativeimage;

import org.graalvm.nativeimage.Platform;
import org.graalvm.nativeimage.hosted.Feature;
import org.graalvm.nativeimage.hosted.RuntimeJNIAccess;

import com.oracle.svm.core.jdk.NativeLibrarySupport;
import com.oracle.svm.core.jdk.PlatformNativeLibrarySupport;
import com.oracle.svm.hosted.FeatureImpl;
import com.oracle.svm.hosted.c.NativeLibraries;

/**
 * Links macOS's Kerberos credential-cache bridge into the native image.
 *
 * <p>On macOS a Kerberos ticket normally lives in an API cache held by the
 * system, not in a file. Java reaches that cache through {@code libosxkrb5},
 * a JDK library loaded with {@code System.loadLibrary} — which a native image
 * has no business doing, since nothing ships the dylib alongside the binary.
 * The symptom is {@code UnsatisfiedLinkError: No osxkrb5 in java.library.path}
 * on a Mac whose {@code klist} output looks perfectly healthy.
 *
 * <p>GraalVM ships the same library as a static archive
 * ({@code lib/static/darwin-aarch64/libosxkrb5.a}), so the fix is to link it
 * into the image and tell the image it is built in, exactly as GraalVM itself
 * treats {@code libjaas} and {@code libnet}. {@code System.loadLibrary} then
 * finds it without a file on disk, and the binary stays self-contained.
 *
 * <p>Everything here is build-time only and macOS only: on Linux
 * {@link #isInConfiguration} returns false and the image is untouched.
 */
public final class MacosKerberosFeature implements Feature {

    /** The JNI prefix of every native method in {@code libosxkrb5}. */
    private static final String KRB5_NATIVE_PREFIX = "sun_security_krb5";

    private static final String CREDENTIALS   = "sun.security.krb5.Credentials";
    private static final String ENCRYPTION_KEY = "sun.security.krb5.EncryptionKey";
    private static final String PRINCIPAL_NAME = "sun.security.krb5.PrincipalName";
    private static final String HOST_ADDRESS   = "sun.security.krb5.internal.HostAddress";
    private static final String HOST_ADDRESSES = "sun.security.krb5.internal.HostAddresses";
    private static final String KERBEROS_TIME  = "sun.security.krb5.internal.KerberosTime";
    private static final String TICKET         = "sun.security.krb5.internal.Ticket";
    private static final String TICKET_FLAGS   = "sun.security.krb5.internal.TicketFlags";

    @Override
    public boolean isInConfiguration(IsInConfigurationAccess access) {
        return Platform.includedIn(Platform.DARWIN.class);
    }

    @Override
    public String getDescription() {
        return "Links the macOS Kerberos credential cache bridge (osxkrb5) into the image";
    }

    @Override
    public void beforeAnalysis(BeforeAnalysisAccess access) {
        // Classify osxkrb5 as built in, so System.loadLibrary("osxkrb5") resolves
        // against the image itself, and route Java_sun_security_krb5_* lookups
        // there rather than to a dylib that will never be on the library path.
        NativeLibrarySupport.singleton().preregisterUninitializedBuiltinLibrary("osxkrb5");
        PlatformNativeLibrarySupport.singleton().addBuiltinPkgNativePrefix(KRB5_NATIVE_PREFIX);

        NativeLibraries libraries = ((FeatureImpl.BeforeAnalysisAccessImpl) access).getNativeLibraries();
        libraries.addStaticJniLibrary("osxkrb5");
        // The archive is only a thin bridge; the Kerberos implementation it calls
        // is the system framework.
        libraries.addDynamicNonJniLibrary("-framework Kerberos");

        registerJniCallbacks(access);
    }

    /**
     * The library returns its answer by constructing Java objects through JNI
     * rather than by returning a struct, so every type it builds has to survive
     * into the image under a name the C code can still find. A missing entry
     * here does not fail the build — it fails at the moment someone logs in,
     * which is the worst possible time to discover it.
     */
    private static void registerJniCallbacks(BeforeAnalysisAccess access) {
        registerConstructor(access, CREDENTIALS,
            TICKET,
            PRINCIPAL_NAME, PRINCIPAL_NAME, PRINCIPAL_NAME, PRINCIPAL_NAME,
            ENCRYPTION_KEY,
            TICKET_FLAGS,
            KERBEROS_TIME, KERBEROS_TIME, KERBEROS_TIME, KERBEROS_TIME,
            HOST_ADDRESSES);
        registerConstructor(access, ENCRYPTION_KEY, "int", "byte[]");
        registerConstructor(access, PRINCIPAL_NAME, "java.lang.String", "int");
        registerConstructor(access, HOST_ADDRESS, "int", "byte[]");
        registerConstructor(access, HOST_ADDRESSES, HOST_ADDRESS + "[]");
        registerConstructor(access, KERBEROS_TIME, "long");
        registerConstructor(access, TICKET, "byte[]");
        registerConstructor(access, TICKET_FLAGS, "int", "byte[]");

        // java.lang.Integer, java.lang.Boolean.getBoolean and java.lang.String are
        // registered unconditionally by GraalVM's own JDK registration, so the
        // library's calls into them are already covered.
    }

    private static void registerConstructor(BeforeAnalysisAccess access, String className, String... parameterTypes) {
        Class<?> clazz = findClass(access, className);
        Class<?>[] parameters = new Class<?>[parameterTypes.length];
        for (int i = 0; i < parameterTypes.length; i++) {
            parameters[i] = findClass(access, parameterTypes[i]);
        }
        RuntimeJNIAccess.register(clazz);
        try {
            RuntimeJNIAccess.register(clazz.getDeclaredConstructor(parameters));
        } catch (NoSuchMethodException e) {
            // A JDK that moved this constructor would otherwise produce a binary
            // that only fails on a Mac with a real ticket, so stop the build here.
            throw new IllegalStateException(
                "osxkrb5 constructor not found on this JDK: " + className + " — native-image metadata needs updating", e);
        }
    }

    private static Class<?> findClass(BeforeAnalysisAccess access, String name) {
        switch (name) {
            case "int":    return int.class;
            case "long":   return long.class;
            case "byte[]": return byte[].class;
            default:       break;
        }
        String elementName = name.endsWith("[]") ? name.substring(0, name.length() - 2) : null;
        String lookup = elementName != null ? "[L" + elementName + ";" : name;
        Class<?> clazz = access.findClassByName(lookup);
        if (clazz == null) {
            throw new IllegalStateException(
                "osxkrb5 class not found on this JDK: " + name + " — native-image metadata needs updating");
        }
        return clazz;
    }
}
