import { showHUD } from "@raycast/api";
import { previewFile } from "swift:../swift/motion-preview";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const SUPPORTED_FILE = /\.(lottie|json|riv)$/i;

// AppleScript that returns the POSIX path of the first Finder selection
// (empty string when nothing is selected or Finder isn't running).
const FINDER_SELECTION_SCRIPT = `
if application "Finder" is not running then
    return ""
end if

tell application "Finder"
    set sel to selection
    if sel is {} then return ""
    return POSIX path of (item 1 of sel as alias)
end tell
`;

/**
 * Gets the first selected Finder item via osascript.
 *
 * We use AppleScript here rather than Raycast's getSelectedFinderItems(): in
 * practice it returns the selection noticeably faster, which shaves the delay
 * before the preview window appears.
 */
const getFinderSelection = async (): Promise<string | undefined> => {
  try {
    const { stdout } = await execFileAsync("osascript", ["-e", FINDER_SELECTION_SCRIPT]);
    const path = stdout.trim();
    return path ? path : undefined;
  } catch {
    // Finder unavailable / Apple Events denied; the caller surfaces this.
    return undefined;
  }
};

const PreviewAnimation = async () => {
  const file = await getFinderSelection();

  if (!file) {
    await showHUD("No file selected");
    return;
  }

  if (!SUPPORTED_FILE.test(file)) {
    await showHUD("Unsupported file format");
    return;
  }

  try {
    // The Swift previewer reads and validates the file before opening its
    // window, so invalid files are rejected here instead of loading.
    await previewFile(file);
  } catch (error) {
    await showHUD(swiftErrorMessage(error) ?? "Could not preview animation");
  }
};

/** Extracts a readable message from a Swift-bridge error (stderr or message). */
const swiftErrorMessage = (error: unknown): string | undefined => {
  if (!error || typeof error !== "object") return undefined;
  const { stderr, message } = error as { stderr?: unknown; message?: unknown };
  if (typeof stderr === "string") {
    const line = stderr
      .split("\n")
      .map((l) => l.trim())
      .find(Boolean);
    if (line) return line;
  }
  return typeof message === "string" && message.trim() ? message.trim() : undefined;
};

export default PreviewAnimation;
