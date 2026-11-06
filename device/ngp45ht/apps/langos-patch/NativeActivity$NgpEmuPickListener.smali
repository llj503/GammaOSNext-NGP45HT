.class Lcom/retrofront/NativeActivity$NgpEmuPickListener;
.super Ljava/lang/Object;
.implements Landroid/content/DialogInterface$OnClickListener;

.source "NativeActivity.kt"


# instance fields
.field final synthetic activity:Lcom/retrofront/NativeActivity;

.field final synthetic game:Lcom/retrofront/data/Game;

.field final synthetic pkgs:[Ljava/lang/String;


# direct methods
.method public constructor <init>(Lcom/retrofront/NativeActivity;Lcom/retrofront/data/Game;[Ljava/lang/String;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->activity:Lcom/retrofront/NativeActivity;

    iput-object p2, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->game:Lcom/retrofront/data/Game;

    iput-object p3, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->pkgs:[Ljava/lang/String;

    return-void
.end method


# virtual methods
.method public onClick(Landroid/content/DialogInterface;I)V
    .locals 3

    iget-object v0, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->pkgs:[Ljava/lang/String;

    aget-object v1, v0, p2

    iget-object v0, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->activity:Lcom/retrofront/NativeActivity;

    iget-object v2, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->game:Lcom/retrofront/data/Game;

    invoke-static {v0, v1, v2}, Lcom/retrofront/NativeActivity;->access$ngpLaunch(Lcom/retrofront/NativeActivity;Ljava/lang/String;Lcom/retrofront/data/Game;)V

    invoke-interface {p1}, Landroid/content/DialogInterface;->dismiss()V

    return-void
.end method
