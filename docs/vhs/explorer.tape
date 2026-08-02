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
Set TypingSpeed 40ms
Set CursorBlink false

Hide
Type "DWE_POSITION=left nvim -u docs/vhs/init.lua -i NONE --noplugin"
Enter
Sleep 5s
Type ":DotnetWorkspaceExplorerFocus"
Enter
Sleep 1s
Show
Sleep 2s

Type "l"
Sleep 1s
Type "j"
Sleep 400ms
Type "l"
Sleep 1s
Type "j"
Sleep 400ms
Type "l"
Sleep 1s
Type "j"
Sleep 400ms
Type "l"
Sleep 1200ms
Type "jj"
Sleep 600ms
Type "l"
Sleep 1s
Type "j"
Sleep 400ms
Enter
Sleep 2s

Type ":DotnetWorkspaceExplorerFocus"
Enter
Sleep 1s
Type "k"
Sleep 400ms
Type "k"
Sleep 400ms
Type "l"
Sleep 1500ms
Type "jjjj"
Sleep 1200ms
Type "gg"
Sleep 600ms
Type "G"
Sleep 1200ms
Type "gg"
Sleep 800ms
Type "4j"
Sleep 400ms
Ctrl+l
Sleep 400ms
Screenshot docs/assets/explorer.png
Sleep 3s

Hide
Type ":qa!"
Enter
