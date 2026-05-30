import { getSelectedFinderItems } from "@raycast/api";

export const getFocusFinderPath = async (): Promise<string | undefined> => {
  try {
    const [item] = await getSelectedFinderItems();
    return item?.path;
  } catch {
    // No Finder selection (or Finder isn't available); the caller surfaces this.
    return undefined;
  }
};

export const hasExt = (path: string, exts: string | string[]) => {
  const extensions = Array.isArray(exts) ? exts : [exts];
  const lowerPath = path.toLowerCase();
  return extensions.some((ext) => lowerPath.endsWith(`.${ext.toLowerCase()}`));
};
