Output docs/assets/explorer.webp

Set Shell "bash"
Set FontSize 19
Set Width 1600
Set Height 900
Set TypingSpeed 18ms
Set Framerate 30
Set Theme "Catppuccin Mocha"

Type "echo 'LEFT — configured mapping preview, then cancel'"
Enter
Sleep 1s
Type "DWE_POSITION=left nvim -u docs/vhs/init.lua -i NONE --noplugin"
Enter
Sleep 7s
Type ":DotnetWorkspaceExplorerFocus"
Enter
Sleep 1s
Type "l"
Sleep 4s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.CSharp"
Enter
Sleep 1s
Type "l"
Sleep 4s
Type "l"
Sleep 3s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.CSharp"
Enter
Type "l"
Sleep 4s
Type "/Dependencies"
Enter
Type "l"
Sleep 3s
Type "/Actions"
Enter
Type "l"
Sleep 3s
Ctrl+d
Sleep 2s
Ctrl+u
Sleep 2s
Type "/P Studio.CSharp"
Enter
Sleep 1s
Type "a"
Sleep 1s
Type "src/Studio.CSharp/Actions/CancelledByMapping.cs"
Enter
Sleep 3s
Type "Cancel"
Enter
Sleep 2s
Type "/P Studio.CSharp"
Enter
Sleep 2s
Type "h"
Type "/P Studio.FSharp"
Enter
Type "l"
Sleep 4s
Type "l"
Sleep 3s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.FSharp"
Enter
Type "l"
Sleep 4s
Type "/Foundation"
Enter
Type "l"
Sleep 2s
Type "/Features"
Enter
Type "l"
Sleep 3s
Ctrl+d
Sleep 2s
Type "/P Studio.FSharp"
Enter
Type "h"
Type "/P Studio.VisualBasic"
Enter
Type "l"
Sleep 4s
Type "l"
Sleep 3s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/P Studio.VisualBasic"
Enter
Type "l"
Sleep 4s
Type "/Presentation"
Enter
Type "l"
Sleep 2s
Type "/Services"
Enter
Type "l"
Sleep 3s
Type ":qa!"
Enter
Sleep 2s

Type "echo 'RIGHT — Ex command create and authoritative refresh'"
Enter
Sleep 1s
Type "DWE_POSITION=right nvim -u docs/vhs/init.lua -i NONE --noplugin"
Enter
Sleep 7s
Type ":DotnetWorkspaceExplorerFocus"
Enter
Sleep 1s
Type "l"
Sleep 4s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.CSharp"
Enter
Sleep 1s
Type "l"
Sleep 4s
Type "l"
Sleep 3s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.CSharp"
Enter
Type "l"
Sleep 4s
Type ":DotnetWorkspaceExplorerAddFile src/Studio.CSharp/Actions/AddedByCommand.cs"
Enter
Sleep 3s
Type "Create"
Enter
Sleep 8s
Type "/SemanticStudio"
Enter
Type "h"
Type "l"
Sleep 3s
Type "/src"
Enter
Type "l"
Sleep 3s
Type "/Applications"
Enter
Type "l"
Sleep 3s
Type "/P Studio.CSharp"
Enter
Type "l"
Sleep 4s
Type "/Actions"
Enter
Sleep 1s
Type "l"
Sleep 3s
Type "/AddedByCommand.cs"
Enter
Sleep 3s
Screenshot docs/assets/explorer.png
Sleep 3s
Type ":qa!"
Enter
Sleep 2s
