// Shared by browser tests and Flutter's Chrome test runner.
export function chromeBinary(env = process.env, platform = process.platform) {
	for (const name of ["CHROME_BIN", "CHROME_BINARY", "CHROME_EXECUTABLE"]) {
		if (env[name]?.trim()) return env[name];
	}
	if (platform === "darwin")
		return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
	if (platform === "win32")
		return `${env.PROGRAMFILES || "C:\\Program Files"}\\Google\\Chrome\\Application\\chrome.exe`;
	return "/usr/bin/google-chrome";
}
