// Windows's own SQLite, which ships with the system (winsqlite3.dll) and whose header comes with the
// Windows SDK, as the Mac app uses the SQLite in the macOS SDK. Only what SQLite needs of the Windows
// headers is pulled in, so names such as UUID stay Foundation's.
#define WIN32_LEAN_AND_MEAN
#include <winsqlite/winsqlite3.h>
