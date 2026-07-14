const { Plugin, Notice } = require("obsidian");
const { shell } = require("electron");

module.exports = class ToskVoicePlugin extends Plugin {
  async onload() {
    this.addCommand({
      id: "edit-selection-with-toskvoice",
      name: "Edit selection with ToskVoice",
      editorCallback: (editor, view) => {
        const selection = editor.getSelection();
        const path = view.file?.path || "the current note";
        const instruction = selection
          ? `Edit ${path}. Here is the selected text for context:\n\n${selection}`
          : `Edit ${path}. Ask me in ToskVoice what should change.`;
        const url = `toskvoice://edit?instruction=${encodeURIComponent(instruction)}`;
        shell.openExternal(url);
        new Notice("Sent to ToskVoice");
      }
    });
  }
};
