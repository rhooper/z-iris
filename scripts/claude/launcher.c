/* z-iris.app's main executable: embeds Homebrew's framework Python and runs
 * `-m z_iris`. Being the bundle's own CFBundleExecutable (not a script that
 * execs a copied Python) lets macOS match the process to ca.toybox.z-iris, so
 * the menubar item is listed as z-iris instead of whatever launched it.
 * 2026-10-19. Built by build_app.sh, which defines Z_IRIS_PYTHONPATH and,
 * for z-iris-priority.app, Z_IRIS_MODULE.
 *
 * With Z_IRIS_EMBEDDED (build_release.sh) the app is self-contained: Python
 * lives in Contents/Resources/python and the code in Contents/Resources/
 * site-packages, found from the executable's own location at run time.
 */
#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef Z_IRIS_EMBEDDED
#include <limits.h>
#include <mach-o/dyld.h>
#endif

#ifndef Z_IRIS_MODULE
#define Z_IRIS_MODULE "z_iris"
#endif

int main(int argc, char **argv) {
	/* Finder, open and login items start with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
	 * which hides sox's play and terminal-notifier. */
	const char *path = getenv("PATH");
	char joined[4096];
	snprintf(joined, sizeof joined, "/opt/homebrew/bin:/usr/local/bin:%s",
	         path ? path : "/usr/bin:/bin:/usr/sbin:/sbin");
	setenv("PATH", joined, 1);
#ifdef Z_IRIS_EMBEDDED
	/* Contents/MacOS/<executable> -> Contents */
	char exe[PATH_MAX], real[PATH_MAX], contents[PATH_MAX], value[PATH_MAX + 64];
	uint32_t size = sizeof exe;
	if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL)
		return 1;
	strlcpy(contents, real, sizeof contents);
	for (int up = 0; up < 2; up++) {  /* drop "/<executable>", then "/MacOS" */
		char *slash = strrchr(contents, '/');
		if (slash == NULL)
			return 1;
		*slash = '\0';
	}
	snprintf(value, sizeof value, "%s/Resources/python", contents);
	setenv("PYTHONHOME", value, 1);
	snprintf(value, sizeof value, "%s/Resources/site-packages", contents);
	setenv("PYTHONPATH", value, 1);
	/* A signed bundle must not change: never write bytecode into it. */
	setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
#else
	setenv("PYTHONPATH", Z_IRIS_PYTHONPATH, 1);
#endif
	setenv("PYTHONNOUSERSITE", "1", 1);

	/* --autoreload re-runs sys.executable -m z_iris ...; pass that through. */
	if (argc > 1 && strcmp(argv[1], "-m") == 0)
		return Py_BytesMain(argc, argv);

	char **args = calloc((size_t)argc + 3, sizeof *args);
	if (args == NULL)
		return 1;
	args[0] = argv[0];
	args[1] = "-m";
	args[2] = Z_IRIS_MODULE;
	for (int i = 1; i < argc; i++)
		args[i + 2] = argv[i];
	return Py_BytesMain(argc + 2, args);
}
