/* z-iris.app's main executable: embeds Homebrew's framework Python and runs
 * `-m z_iris`. Being the bundle's own CFBundleExecutable (not a script that
 * execs a copied Python) lets macOS match the process to ca.toybox.z-iris, so
 * the menubar item is listed as z-iris instead of whatever launched it.
 * 2026-10-19. Built by build_app.sh, which defines Z_IRIS_PYTHONPATH.
 */
#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
	/* Finder, open and login items start with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
	 * which hides sox's play and terminal-notifier. */
	const char *path = getenv("PATH");
	char joined[4096];
	snprintf(joined, sizeof joined, "/opt/homebrew/bin:/usr/local/bin:%s",
	         path ? path : "/usr/bin:/bin:/usr/sbin:/sbin");
	setenv("PATH", joined, 1);
	setenv("PYTHONPATH", Z_IRIS_PYTHONPATH, 1);
	setenv("PYTHONNOUSERSITE", "1", 1);

	/* --autoreload re-runs sys.executable -m z_iris ...; pass that through. */
	if (argc > 1 && strcmp(argv[1], "-m") == 0)
		return Py_BytesMain(argc, argv);

	char **args = calloc((size_t)argc + 3, sizeof *args);
	if (args == NULL)
		return 1;
	args[0] = argv[0];
	args[1] = "-m";
	args[2] = "z_iris";
	for (int i = 1; i < argc; i++)
		args[i + 2] = argv[i];
	return Py_BytesMain(argc + 2, args);
}
