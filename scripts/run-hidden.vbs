' Runs a console program without a window and returns its exit code.
'
'   wscript.exe //B //Nologo run-hidden.vbs "C:\path\program.exe" [arguments...]
'
' A task that runs in your session flashes a console window every time it starts a console
' program, even with -WindowStyle Hidden, because the window exists before PowerShell can hide it.
' wscript.exe is a windowed program, so nothing appears. Waiting for the program and returning its
' exit code keeps failures visible in the task's Last Run Result. Errors are handled explicitly
' because under //B a runtime error in this script would quit with 0 and hide the failure.

Option Explicit

Dim args, i, commandLine, code

Set args = WScript.Arguments
If args.Count = 0 Then WScript.Quit 2

commandLine = ""
For i = 0 To args.Count - 1
    If i > 0 Then commandLine = commandLine & " "
    commandLine = commandLine & Quote(args(i))
Next

On Error Resume Next
code = CreateObject("WScript.Shell").Run(commandLine, 0, True)
If Err.Number <> 0 Then WScript.Quit 1
On Error Goto 0

WScript.Quit code

' WScript.Arguments drops the quotes it received, so they are put back where a space needs them.
Function Quote(value)
    If Len(value) = 0 Or InStr(value, " ") > 0 Or InStr(value, vbTab) > 0 Then
        Quote = """" & value & """"
    Else
        Quote = value
    End If
End Function
