# Mac release smoke test

Record the commit, macOS version, Xcode version, and signed build under test. Use a dedicated macOS test account with a disposable System Photo Library for the Photos steps.

| Check | Expected result |
|---|---|
| Drop a folder containing two videos with the same name in different subfolders. Append one of them again. | Both distinct videos appear with their original names. The duplicate is skipped. |
| Select clips using the arrow keys at wide and narrow window sizes. | The queue, selected editor, and pinned action bar remain usable. Delete removes the selected row. |
| Set Custom in trim defaults and select a long clip. Adjust defaults again. | The viewed clip inherits the change. Dragging a handle or editing a numeric field affects that clip. Reset restores inheritance. |
| Play a custom segment, scrub, choose a cover and step one frame. Repeat with a short clip. | Motion stays inside the selected segment. The cover thumbnail and marker follow the edit. A short clip keeps its full duration. |
| Select Folder and start the first export. Choose a folder in the picker. | Export continues immediately. Both resources share a source-based name. Existing files survive. Reveal in Finder opens that folder. |
| Switch that queue to Photos, enter a new album name, and save. | Granting access creates one playable Live Photo per clip in that album. Check the still, motion, orientation and sound. A repeat run shows zero eligible clips. |
| Edit a cover, then switch between two destinations. | Only the edited clip needs delivery to each previous destination. Counts refer to this run. |
| Deny Photos permission in the test account, then restore it and retry. | The error is actionable. Folder export remains available. Retry saves the failed items. |
| Stop a multi-item batch, then resume. | The current clip finishes, remaining clips stay pending, and completed clips are skipped on resume. |
| Relaunch the sandboxed app and export to the remembered folder. | The folder is writable without choosing it again. |

Run `swift test` for the simulated album-add failure and tests of metadata, geometry, cleanup, and recovery. Record any failing manual step and the diagnostic log from Help.
