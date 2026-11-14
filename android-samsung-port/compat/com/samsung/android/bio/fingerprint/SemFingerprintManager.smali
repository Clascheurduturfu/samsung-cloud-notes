# Samsung's biometric service is unavailable on generic Android. A null manager
# follows the native app's existing unsupported-hardware branch; it never unlocks.
.class public final Lcom/samsung/android/bio/fingerprint/SemFingerprintManager;
.super Ljava/lang/Object;

.method public static createInstance(Landroid/content/Context;)Lcom/samsung/android/bio/fingerprint/SemFingerprintManager;
    .locals 1
    const/4 v0, 0x0
    return-object v0
.end method

.method public hasEnrolledFingerprints()Z
    .locals 1
    const/4 v0, 0x0
    return v0
.end method
