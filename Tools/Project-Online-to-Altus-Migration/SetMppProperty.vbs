' SetMppProperty.vbs
' Sets one or more custom properties in an MS Project MPP file
' Usage: cscript SetMppProperty.vbs <FilePath> <PropertyName1> <PropertyValue1> [<PropertyName2> <PropertyValue2> ...] <ExecutionMode>

Option Explicit

Dim msProject, filePath, activeProject, customProps
Dim objArgs, i, propName, propValue, propCount, executionMode, shouldSave

' Get command line arguments
Set objArgs = WScript.Arguments
If objArgs.Count < 4 Then
    WScript.Echo "Error: Missing arguments"
    WScript.Echo "Usage: cscript SetMppProperty.vbs <FilePath> <PropertyName1> <PropertyValue1> [<PropertyName2> <PropertyValue2> ...] <ExecutionMode>"
    WScript.Quit 1
End If

' Last argument is ExecutionMode (True/False)
executionMode = objArgs(objArgs.Count - 1)
shouldSave = (LCase(executionMode) = "true")

' Check that we have property name/value pairs (even number of args after filepath and before ExecutionMode)
If (objArgs.Count - 2) Mod 2 <> 0 Then
    WScript.Echo "Error: Property names and values must be in pairs"
    WScript.Echo "Usage: cscript SetMppProperty.vbs <FilePath> <PropertyName1> <PropertyValue1> [<PropertyName2> <PropertyValue2> ...] <ExecutionMode>"
    WScript.Quit 1
End If

filePath = objArgs(0)
propCount = (objArgs.Count - 2) / 2

WScript.Echo "Properties to set: " & propCount
WScript.Echo "Execution Mode: " & executionMode & " (Save changes: " & shouldSave & ")"

On Error Resume Next

' Create MS Project COM object
WScript.Echo "Creating MS Project COM object..."
Set msProject = CreateObject("MSProject.Application")
If Err.Number <> 0 Then
    WScript.Echo "Error: Could not create MS Project COM object: " & Err.Description
    WScript.Quit 1
End If

' Configure MS Project
msProject.Visible = True
msProject.DisplayAlerts = True

' Open the file with parameters to skip recovery and open read-write
WScript.Echo "Opening file: " & filePath
On Error Resume Next
' Parameters: FilePath, ReadOnly
msProject.FileOpen filePath, False
If Err.Number <> 0 Then
    WScript.Echo "Error: Could not open file: " & Err.Description & " (Error Number: " & Err.Number & ")"
    On Error Goto 0
    msProject.Quit
    WScript.Quit 1
End If
On Error Goto 0

' Give it a moment to load
WScript.Echo "Waiting for file to load..."
WScript.Sleep 2000

' Get active project with retry logic
WScript.Echo "Accessing ActiveProject..."
Dim retryCount, maxRetries
maxRetries = 5
retryCount = 0

On Error Resume Next
Set activeProject = msProject.ActiveProject

Do While (Err.Number <> 0 Or activeProject Is Nothing) And retryCount < maxRetries
    retryCount = retryCount + 1
    WScript.Echo "  Retry " & retryCount & " of " & maxRetries & "..."
    Err.Clear
    WScript.Sleep 1000
    Set activeProject = msProject.ActiveProject
Loop

If Err.Number <> 0 Or activeProject Is Nothing Then
    WScript.Echo "Error: Could not access ActiveProject after " & maxRetries & " retries: " & Err.Description
    On Error Goto 0
    msProject.FileClose False
    msProject.Quit
    WScript.Quit 1
End If
On Error Goto 0

WScript.Echo "Project loaded: " & activeProject.Name

' Get custom properties
WScript.Echo "Accessing CustomDocumentProperties..."
On Error Resume Next
Set customProps = activeProject.CustomDocumentProperties
If Err.Number <> 0 Then
    WScript.Echo "Error: Could not access CustomDocumentProperties: " & Err.Description
    On Error Goto 0
    msProject.FileClose False
    msProject.Quit
    WScript.Quit 1
End If

' Track whether any changes were made
Dim changesMade
changesMade = False

' Loop through property name/value pairs (excluding the last ExecutionMode argument)
For i = 1 To objArgs.Count - 2 Step 2
    propName = objArgs(i)
    propValue = objArgs(i + 1)
    
    WScript.Echo "Setting property '" & propName & "' = '" & propValue & "'..."
    Err.Clear
    
    ' Check if property exists and has the same value
    Dim existingValue, propertyExists
    propertyExists = False
    existingValue = ""
    
    On Error Resume Next
    existingValue = customProps.Item(propName).Value
    If Err.Number = 0 Then
        propertyExists = True
    End If
    Err.Clear
    On Error Goto 0
    
    ' Only update if property doesn't exist or value is different
    If Not propertyExists Then
        ' Property doesn't exist, add it
        On Error Resume Next
        customProps.Add propName, False, 4, propValue ' 4 = msoPropertyTypeString
        If Err.Number <> 0 Then
            WScript.Echo "Error: Could not add property '" & propName & "': " & Err.Description
            msProject.FileClose False
            msProject.Quit
            WScript.Quit 1
        End If
        On Error Goto 0
        WScript.Echo "  Property '" & propName & "' added successfully"
        changesMade = True
    ElseIf existingValue <> propValue Then
        ' Property exists but value is different, update it
        On Error Resume Next
        customProps.Item(propName).Value = propValue
        If Err.Number <> 0 Then
            WScript.Echo "Error: Could not update property '" & propName & "': " & Err.Description
            msProject.FileClose False
            msProject.Quit
            WScript.Quit 1
        End If
        On Error Goto 0
        WScript.Echo "  Property '" & propName & "' updated successfully (was: '" & existingValue & "')"
        changesMade = True
    Else
        WScript.Echo "  Property '" & propName & "' already has correct value, skipping"
    End If
Next

' Save and close only if changes were made AND ExecutionMode is True
If changesMade And shouldSave Then
    WScript.Echo "Saving file..."
    On Error Resume Next
    msProject.FileSave
    If Err.Number <> 0 Then
        WScript.Echo "Error: Could not save file: " & Err.Description
        msProject.FileClose False
        msProject.Quit
        WScript.Quit 1
    End If
    On Error Goto 0
    WScript.Echo "File saved successfully"
ElseIf changesMade And Not shouldSave Then
    WScript.Echo "Changes detected but ExecutionMode is False (What-If mode), skipping save"
Else
    WScript.Echo "No changes made, skipping save"
End If

WScript.Echo "Closing file..."
msProject.FileClose False
msProject.Quit

' Cleanup
Set customProps = Nothing
Set activeProject = Nothing
Set msProject = Nothing

WScript.Echo "Success: All custom properties evaluated successfully"
WScript.Quit 0
