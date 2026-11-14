"""Auth-contract replacements authored here; vendor implementations are never copied."""
from pathlib import Path
import re

BRIDGE = "Llocal/samsungcloudnotes/nativebridge/NotesBridge;"


def read_only_folder_phase(text: str) -> str:
    # This phase precedes note downsync. Skipping the entire upload phase also
    # avoids clearing pending folder edits after an upload that never happened.
    anchor = '    const-string v0, "Folder (upSync)"'
    if text.count(anchor) != 1 or text.count("    :cond_1f\n") != 1:
        raise ValueError("Unsupported input: native folder upload phase differs")
    return text.replace(anchor, f"    invoke-static {{}}, {BRIDGE}->isNativeReadOnly()Z\n    move-result v0\n    if-nez v0, :cond_1f\n\n" + anchor, 1)


def guard_note_uploads(text: str) -> str:
    pattern = re.compile(r"(^\.method public final l\(\)V\n    \.locals \d+\n)", re.M)
    guard = f"""
    invoke-static {{p0}}, {BRIDGE}->skipNativeUploads(Ljava/lang/Object;)Z
    move-result v0
    if-eqz v0, :cloud_beta_native_uploads
    return-void
    :cloud_beta_native_uploads
"""
    result, count = pattern.subn(lambda match: match[0] + guard, text)
    if count != 1 or ":cloud_beta_native_uploads" in text:
        raise ValueError("Unsupported input: native note upload phase differs")
    return result


def connect_web_account_controller(text: str) -> str:
    # Samsung wires the token controller only in its LOCAL account branch.
    # A real independent web sign-in needs that same link in the WEB branch;
    # otherwise the first logged-in state transition dereferences a null field.
    before = """    invoke-direct {v0, v1}, Ln3/i;-><init>(Landroid/content/Context;)V

    iput-object v0, p0, Ln3/j;->a:Ljava/lang/Object;"""
    after = """    invoke-direct {v0, v1}, Ln3/i;-><init>(Landroid/content/Context;)V

    iget-object v2, p0, Ln3/j;->b:Ljava/lang/Object;
    check-cast v2, Ln3/e;
    iput-object v2, v0, Ln3/i;->f:Ln3/e;
    iput-object v0, p0, Ln3/j;->a:Ljava/lang/Object;"""
    if text.count(before) != 1:
        raise ValueError("Unsupported input: WEB account controller construction differs")
    return text.replace(before, after, 1)


def method(text: str, signature: str, body: str) -> str:
    pattern = re.compile(r"^\.method " + re.escape(signature) + r"\n.*?^\.end method$", re.M | re.S)
    replacement = f".method {signature}\n{body.rstrip()}\n.end method"
    result, count = pattern.subn(lambda _: replacement, text)
    if count != 1:
        raise ValueError(f"Unsupported input: expected one method {signature}, found {count}")
    return result


def getter(target: str, result: str = "Ljava/lang/String;") -> str:
    kind = "-object" if result.startswith("L") else ""
    return f"    .locals 1\n    invoke-static {{}}, {BRIDGE}->{target}(){result}\n    move-result{kind} v0\n    return{kind} v0"


def compatibility_hooks(decoded: Path) -> dict[Path, str]:
    # Samsung clipboard history filtering eagerly instantiates an interface
    # absent on AOSP. Ordinary Android copy/paste follows separate native paths.
    path = decoded / "smali_classes2/com/samsung/android/support/senl/nt/composer/main/base/presenter/controller/ClipboardController.smali"
    text = method(path.read_text(encoding="utf-8"), "public setClipboardFilter(ILjava/lang/String;)V", "    .locals 0\n    return-void")
    changes = {path: text}
    # Zero means no Samsung platform version. Do not invent One UI capability.
    version_users = (
        "smali_classes11/com/sec/android/diagmonagent/log/provider/utils/DiagMonUtil.smali",
        "smali_classes11/com/sec/android/diagmonagent/dma/aperf/utils/aPerfValidation.smali",
        "smali_classes6/com/samsung/android/support/senl/nt/composer/main/base/view/menu/search/SearchModeView.smali",
        "smali_classes10/com/samsung/android/support/senl/nt/base/widget/search/VoiceButtonHelper.smali",
        "smali_classes9/com/samsung/android/sdk/scs/base/feature/Feature.smali",
        "smali_classes9/com/samsung/android/sdk/scs/ai/image/ImageUpscaler.smali",
        "smali_classes8/com/samsung/android/app/sdk/deepsky/textextraction/util/Rune.smali",
    )
    pattern = re.compile(r"sget ([vp]\d+), Landroid/os/Build\$VERSION;->SEM_PLATFORM_INT:I")
    for relative in version_users:
        path = decoded / relative
        original = path.read_text(encoding="utf-8")
        modified, count = pattern.subn(r"const/16 \1, 0x0", original)
        if count < 1:
            raise ValueError(f"Unsupported input: Samsung platform field missing in {relative}")
        changes[path] = modified
    path = decoded / "smali_classes9/com/samsung/android/support/senl/nt/app/main/noteslist/adapter/view/ViewInflater$ViewContainer.smali"
    original = path.read_text(encoding="utf-8")
    modified, count = re.subn(r"invoke-virtual \{[^}]+\}, Landroid/widget/TextView;->semSetMultiSelectionEnabled\(Z\)V", "nop", original)
    if count != 1:
        raise ValueError("Unsupported input: thumbnail Samsung multi-selection call differs")
    changes[path] = modified
    return changes


def native_hooks(decoded: Path) -> dict[Path, str]:
    changes: dict[Path, str] = {}

    def edit(relative: str, signature: str, body: str) -> None:
        path = decoded / relative
        changes[path] = method(changes.get(path, path.read_text(encoding="utf-8")), signature, body)

    account = "smali_classes8/n3/j.smali"
    for original, replacement in [("c", "accessToken"), ("f", "userId"), ("g", "userHash")]:
        edit(account, f"public {original}()Ljava/lang/String;", getter(replacement))
    edit(account, "public k(Lcom/samsung/android/support/senl/nt/base/common/sync/IAuthInfoReqListener;)V",
         f"    .locals 0\n    invoke-static {{p1}}, {BRIDGE}->requestAuth(Ljava/lang/Object;)V\n    return-void")
    edit(account, "public l()V", f"    .locals 0\n    invoke-static {{}}, {BRIDGE}->invalidate()V\n    return-void")
    edit("smali_classes8/n3/e.smali", "public a(Lcom/samsung/android/support/senl/nt/base/common/sync/IAuthInfoReqListener;)V",
         f"    .locals 0\n    invoke-static {{p1}}, {BRIDGE}->requestAuth(Ljava/lang/Object;)V\n    return-void")
    account_path = decoded / account
    changes[account_path] = connect_web_account_controller(changes[account_path])
    # Keep the native login controller and its listener notifications. Replace
    # only the Samsung AccountManager/provider lookup with the signed-in name.
    edit("smali_classes8/com/samsung/android/app/notes/sync/saccount/samsungaccountclient/j.smali",
         "public static a(Landroid/content/Context;)Ljava/lang/String;", getter("accountName"))
    contract = "smali_classes8/com/samsung/android/model/contractimpl/RequestSamsungAccountContractImpl.smali"
    edit(contract, "public getApiServerUrl()Ljava/lang/String;", getter("accountServer"))
    # Only replace the Samsung-brand/account-package availability test. The
    # surrounding disaster-network, power, demo-device and Knox checks remain.
    edit("smali_classes10/com/samsung/android/support/senl/nt/base/common/util/DeviceUtils.smali",
         "public final isSupportedAccount(Landroid/content/Context;)Z", getter("isAccountProviderAvailable", "Z"))
    # Generic Android supports the bundled AndroidX FileProvider. The original
    # One UI version gate wrongly sends exports through legacy MediaStore _data.
    edit("smali_classes10/com/samsung/android/support/senl/nt/base/common/util/DeviceUtils.smali",
         "public static final isSupportedFileProvider()Z", "    .locals 1\n    const/4 v0, 0x1\n    return v0")
    edit("smali_classes8/j3/a.smali", "public static c()Ljava/util/ArrayList;", getter("requiredSyncPermissions", "Ljava/util/ArrayList;"))
    helper = "smali_classes9/com/samsung/android/support/senl/nt/app/account/AccountHelper.smali"
    for name in ["getLoginSamsungAccountPopupIntent", "getRequestAccessTokenIntent"]:
        edit(helper, f"public static {name}(Landroid/content/Context;)Landroid/content/Intent;",
             f"    .locals 1\n    invoke-static {{p0}}, {BRIDGE}->accountIntent(Landroid/content/Context;)Landroid/content/Intent;\n    move-result-object v0\n    return-object v0")
    for name in ["loginPopupSamsungAccount", "loginRequestAccessToken"]:
        edit(helper, f"public static {name}(Landroid/app/Activity;I)V",
             f"    .locals 0\n    invoke-static {{p0, p1}}, {BRIDGE}->openAccount(Landroid/app/Activity;I)V\n    return-void")
    cloud = "smali_classes8/q3/b.smali"
    edit(cloud, "public i(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", getter("cloudAuthorization"))
    edit(cloud, "public h(Ljava/lang/String;Ljava/lang/String;Lcom/samsung/android/support/senl/nt/base/common/sync/IAuthorizationListener;)V",
         f"    .locals 0\n    invoke-static {{p3}}, {BRIDGE}->requestCloudAuthorization(Ljava/lang/Object;)V\n    return-void")
    edit("smali_classes8/q3/c.smali", "public final b(Ljava/lang/String;)Ljava/lang/String;",
         f"    .locals 1\n    invoke-static {{p1}}, {BRIDGE}->serverUrl(Ljava/lang/String;)Ljava/lang/String;\n    move-result-object v0\n    return-object v0")
    path = decoded / "smali_classes8/c4/d.smali"
    changes[path] = read_only_folder_phase(path.read_text(encoding="utf-8"))
    # Leave dirty note state pending. The HTTP boundary remains a separate
    # fail-closed safeguard for other mutation paths and unexpected operations.
    path = decoded / "smali_classes8/c4/e.smali"
    changes[path] = guard_note_uploads(path.read_text(encoding="utf-8"))
    path = decoded / "smali_classes8/com/samsung/android/app/notes/sync/synchronization/core/tasks/SyncBaseTask.smali"
    source = path.read_text(encoding="utf-8")
    boundary = ".method private onSyncEnded()V\n    .locals 3\n"
    if source.count(boundary) != 1:
        raise ValueError("Unsupported input: native completion callback differs")
    changes[path] = source.replace(boundary, boundary + f"\n    iget v0, p0, Lcom/samsung/android/app/notes/sync/synchronization/core/tasks/SyncBaseTask;->mErrorCode:I\n    invoke-static {{v0}}, {BRIDGE}->nativeSyncEnded(I)V\n", 1)
    path = decoded / "smali_classes4/com/samsung/android/support/senl/nt/model/documents/file/DocumentFileManager.smali"
    source = path.read_text(encoding="utf-8")
    boundary = ".method private onDocumentOpened(Lcom/samsung/android/sdk/pen/worddoc/SpenWNote;Ljava/lang/String;Ljava/lang/String;)V\n    .locals 2\n"
    if source.count(boundary) != 1:
        raise ValueError("Unsupported input: native document-open callback differs")
    changes[path] = source.replace(boundary, boundary + "\n    invoke-static {p1}, Llocal/samsungcloudnotes/nativebridge/NativeCanvas;->prepare(Ljava/lang/Object;)V\n", 1)
    # All note HTTP requests in this audited version are created here, including
    # streaming transfers. m is instantiated only by this factory. Gate before
    # construction so a blocked request cannot reach Apache HttpClient.
    path = decoded / "smali_classes8/com/samsung/android/app/notes/sync/network/networkutils/l.smali"
    source = path.read_text(encoding="utf-8")
    boundary = ".method public final c()Lcom/samsung/android/app/notes/sync/network/networkutils/m;\n    .locals 4\n"
    if source.count(boundary) != 1 or ":cloud_beta_request_allowed" in source:
        raise ValueError("Unsupported input: native request factory differs")
    owner = "Lcom/samsung/android/app/notes/sync/network/networkutils/l;"
    guard = f"""
    iget-object v2, p0, {owner}->e:Ljava/lang/String;
    iget-object v3, p0, {owner}->f:Ljava/lang/String;
    invoke-static {{v2, v3}}, {BRIDGE}->allowNativeRequest(Ljava/lang/String;Ljava/lang/String;)Z
    move-result v2
    if-nez v2, :cloud_beta_request_allowed
    new-instance v2, Lcom/samsung/android/app/notes/sync/error/SyncException;
    const/16 v3, 0x1f3
    const-string v0, "Cloud beta read-only mode blocked a native write."
    invoke-direct {{v2, v3, v0}}, Lcom/samsung/android/app/notes/sync/error/SyncException;-><init>(ILjava/lang/String;)V
    throw v2
    :cloud_beta_request_allowed
"""
    changes[path] = source.replace(boundary, boundary + guard, 1)
    return changes
