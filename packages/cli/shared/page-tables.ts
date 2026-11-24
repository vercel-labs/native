// Where a release build writes the compiled page and style tables: the runtime reads them at
// startup from the app bundle's resources, so the tables travel with the app as data rather than
// being compiled into its executable. They sit in the build's own directory, as a dev build's
// files do in the app's, whose name no file the page names can take.

/** The directory the tables sit in, inside the bundle's resources. */
export const PAGE_TABLES_DIR = ".native";

/** The tables' file, inside PAGE_TABLES_DIR. */
export const PAGE_TABLES_FILE = "page.json";
