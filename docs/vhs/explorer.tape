# Run the owner's VHS fork with --capture-mode=webgl.
Output docs/assets/explorer.webp

Require nvim

Set Shell zsh
Set Theme "Catppuccin Mocha"
Set WindowBar ColorfulRight
Set WindowBarSize 16

Set FontFamily "MesloLGS Nerd Font"
Set FontSize 20

Set Width 1600
Set Height 900
Set BorderRadius 9
Set Padding 0
Set Margin 40
Set MarginFill "docs/vhs/window-shadow.png"

Set Framerate 30
Set PlaybackSpeed 1
Set TypingSpeed 1ms
Set CursorBlink false

Hide
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
Type "/Studio.CSharp"
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
Type "/Studio.CSharp"
Enter
Type "l"
Sleep 4s
Type "/Dependencies"
Enter
Type "l"
Sleep 2s
Type "/Actions"
Enter
Type "l"
Sleep 2s
Type ":nohlsearch"
Enter
Type "gg"
Ctrl+l
Sleep 1s
Show
Sleep 4s

Hide
Ctrl+d
Ctrl+d
Ctrl+l
Sleep 1s
Show
Sleep 4s

Hide
Type "gg"
Type ":wincmd L"
Enter
Ctrl+l
Sleep 1s
Show
Sleep 4s
Screenshot docs/assets/explorer.png
Sleep 2s

Hide
Type ":qa!"
Enter
