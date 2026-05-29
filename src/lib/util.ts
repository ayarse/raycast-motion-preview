import { showHUD } from "@raycast/api";
import { runAppleScript } from "@raycast/utils";

export const scriptFinderPath = `
if application "Finder" is not running then
    return "Finder not running"
end if

tell application "Finder"
    set sel to selection
    if sel is {} then return ""
    return POSIX path of (item 1 of sel as alias)
end tell
`;

export const getFocusFinderPath = async () => {
  try {
    return await runAppleScript(scriptFinderPath);
  } catch (e) {
    if (e instanceof Error) {
      await showHUD(`Error: ${e.message}`);
      return;
    }
    await showHUD("An unknown error occurred");
  }
};

export const hasExt = (path: string, exts: string | string[]) => {
  const extensions = Array.isArray(exts) ? exts : [exts];
  const lowerPath = path.toLowerCase();
  return extensions.some((ext) => lowerPath.endsWith(`.${ext.toLowerCase()}`));
};
