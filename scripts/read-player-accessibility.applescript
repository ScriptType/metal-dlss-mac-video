-- Read the actual native/WebKit accessibility tree of one running player PID.
-- Usage: osascript scripts/read-player-accessibility.applescript PID
on run arguments
    set playerPID to item 1 of arguments as integer
    set outputLines to {"role" & tab & "title" & tab & "description" & tab & "enabled"}
    tell application "System Events"
        set playerProcess to first application process whose unix id is playerPID
        set playerWindow to missing value
        repeat 20 times
            set playerWindow to value of attribute "AXMainWindow" of playerProcess
            if playerWindow is not missing value then exit repeat
            delay 0.1
        end repeat
        if playerWindow is missing value then error "The player has no accessible main window. Bring its window to the foreground and retry."
        set nodes to entire contents of playerWindow
        repeat with node in nodes
            set nodeRole to ""
            set nodeTitle to ""
            set nodeDescription to ""
            set nodeEnabled to ""
            try
                set nodeRole to value of attribute "AXRole" of node as text
            end try
            try
                set nodeTitle to value of attribute "AXTitle" of node as text
            end try
            try
                set nodeDescription to value of attribute "AXDescription" of node as text
            end try
            try
                set nodeEnabled to value of attribute "AXEnabled" of node as text
            end try
            set end of outputLines to nodeRole & tab & nodeTitle & tab & nodeDescription & tab & nodeEnabled
        end repeat
    end tell
    set previousDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to linefeed
    set resultText to outputLines as text
    set AppleScript's text item delimiters to previousDelimiters
    return resultText
end run
