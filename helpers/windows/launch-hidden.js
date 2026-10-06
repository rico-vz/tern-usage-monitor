// wscript hides the console window Tern would otherwise open for each process
var shell = new ActiveXObject("WScript.Shell");
var parts = [];
for (var i = 0; i < WScript.Arguments.length; i++) {
	var arg = WScript.Arguments(i);
	parts.push('"' + arg.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1") + '"');
}
WScript.Quit(shell.Run(parts.join(" "), 0, true));
