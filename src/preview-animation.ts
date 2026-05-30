import { getFocusFinderPath, hasExt } from "./lib/util";
import { showHUD } from "@raycast/api";
import { previewFile } from "swift:../swift/motion-preview";

const PreviewAnimation = async () => {
  const currentFile = await getFocusFinderPath();
  if (!currentFile) {
    await showHUD("No file selected");
    return;
  }

  if (!hasExt(currentFile, ["lottie", "json", "riv"])) {
    await showHUD("Unsupported file format");
    return;
  }

  try {
    // Validation (for Lottie JSON), file reading, and rendering all happen in the
    // Swift previewer, so the file is read once and any failure comes back here.
    await previewFile(currentFile);
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
