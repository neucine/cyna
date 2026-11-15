const cp = require("child_process");
const fs = require("fs");
const path = require("path");
const vscode = require("vscode");

const DIAGNOSTIC_SOURCE = "cyna";
const CHECK_DEBOUNCE_MS = 300;
const WORD_PATTERN = /[A-Za-z_][A-Za-z0-9_]*/;
const LSP_METHODS = {
  initialize: "initialize",
  initialized: "initialized",
  shutdown: "shutdown",
  exit: "exit",
  didOpen: "textDocument/didOpen",
  didChange: "textDocument/didChange",
  didClose: "textDocument/didClose",
  documentSymbol: "textDocument/documentSymbol",
  hover: "textDocument/hover",
  definition: "textDocument/definition",
  publishDiagnostics: "textDocument/publishDiagnostics",
};
const KEYWORD_SET = [
  "fn",
  "struct",
  "c",
  "packed",
  "enum",
  "flags",
  "union",
  "interface",
  "impl",
  "type",
  "const",
  "var",
  "return",
  "if",
  "else",
  "while",
  "for",
  "continue",
  "in",
  "switch",
  "throw",
  "catch",
  "yield",
  "pub",
  "import",
  "from",
  "extern",
  "export",
  "try",
  "check",
  "copy",
  "defer",
  "drop",
  "new",
  "unchecked",
  "using",
  "alloc",
  "scoped",
  "distinct",
  "comptime",
  "asm",
  "is",
  "as",
  "and",
  "or",
  "not",
  "true",
  "false",
  "none",
];
const KEYWORD_COMPLETIONS = [
  ...KEYWORD_SET,
];

let collection;
const timers = new Map();
let lspClient = null;

function activate(context) {
  collection = vscode.languages.createDiagnosticCollection(DIAGNOSTIC_SOURCE);
  context.subscriptions.push(collection);
  lspClient = new CynaLspClient(collection);
  context.subscriptions.push(lspClient);
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider({ language: "cyna" }, createDefinitionProvider()),
    vscode.languages.registerHoverProvider({ language: "cyna" }, createHoverProvider()),
    vscode.languages.registerDocumentSymbolProvider({ language: "cyna" }, createDocumentSymbolProvider()),
    vscode.languages.registerCompletionItemProvider({ language: "cyna" }, createCompletionProvider()),
    vscode.languages.registerDocumentHighlightProvider({ language: "cyna" }, createDocumentHighlightProvider()),
    vscode.languages.registerReferenceProvider({ language: "cyna" }, createReferenceProvider()),
    vscode.languages.registerRenameProvider({ language: "cyna" }, createRenameProvider())
  );

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((document) => {
      scheduleCheck(document);
      lspClient?.didOpen(document);
    }),
    vscode.workspace.onDidSaveTextDocument((document) => scheduleCheck(document)),
    vscode.workspace.onDidCloseTextDocument((document) => {
      collection.delete(document.uri);
      clearTimer(document.uri);
      lspClient?.didClose(document);
    }),
    vscode.workspace.onDidChangeTextDocument((event) => {
      const config = vscode.workspace.getConfiguration("cyna", event.document.uri);
      if (config.get("diagnostics.validateOnChange")) scheduleCheck(event.document);
      lspClient?.didChange(event.document);
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("cyna")) {
        lspClient?.restart();
        for (const document of vscode.workspace.textDocuments) scheduleCheck(document);
      }
    })
  );

  for (const document of vscode.workspace.textDocuments) {
    scheduleCheck(document);
    lspClient.didOpen(document);
  }
}

function deactivate() {
  for (const timer of timers.values()) clearTimeout(timer);
  timers.clear();
  if (lspClient) {
    lspClient.dispose();
    lspClient = null;
  }
  if (collection) collection.dispose();
}

class CynaLspClient {
  constructor(collection) {
    this.collection = collection;
    this.child = null;
    this.buffer = Buffer.alloc(0);
    this.nextRequestId = 1;
    this.pending = new Map();
    this.openDocuments = new Map();
    this.initialized = false;
    this.startPromise = null;
  }

  dispose() {
    this.stop();
  }

  restart() {
    this.stop();
    for (const document of vscode.workspace.textDocuments) {
      if (isCynaDocument(document)) this.didOpen(document);
    }
  }

  didOpen(document) {
    if (!this.shouldUseLsp(document)) return;
    this.openDocuments.set(document.uri.toString(), {
      uri: document.uri.toString(),
      languageId: document.languageId,
      version: document.version,
      text: document.getText(),
    });
    this.ensureStarted()
      .then(() =>
        this.sendNotification(LSP_METHODS.didOpen, {
          textDocument: this.openDocuments.get(document.uri.toString()),
        })
      )
      .catch((error) => this.reportTransportError(document.uri, error));
  }

  didChange(document) {
    if (!this.shouldUseLsp(document)) return;
    const entry = {
      uri: document.uri.toString(),
      languageId: document.languageId,
      version: document.version,
      text: document.getText(),
    };
    this.openDocuments.set(document.uri.toString(), entry);
    this.ensureStarted()
      .then(() =>
        this.sendNotification(LSP_METHODS.didChange, {
          textDocument: {
            uri: entry.uri,
            version: entry.version,
          },
          contentChanges: [{ text: entry.text }],
        })
      )
      .catch((error) => this.reportTransportError(document.uri, error));
  }

  didClose(document) {
    const key = document.uri.toString();
    const tracked = this.openDocuments.get(key);
    this.openDocuments.delete(key);
    if (!tracked || !this.initialized) return;
    this.sendNotification(LSP_METHODS.didClose, {
      textDocument: { uri: tracked.uri },
    }).catch(() => {});
  }

  shouldUseLsp(document) {
    if (!isCynaDocument(document)) return false;
    const config = vscode.workspace.getConfiguration("cyna", document.uri);
    return config.get("diagnostics.enabled");
  }

  async ensureStarted() {
    if (this.initialized) return;
    if (!this.startPromise) this.startPromise = this.start();
    return this.startPromise;
  }

  async start() {
    const command = resolveLspCommand();
    if (!command) throw new Error("Unable to resolve a Cyna LSP command.");

    this.child = cp.spawn(command.command, command.args, {
      cwd: command.cwd,
      shell: false,
      windowsHide: true,
    });

    this.child.stdout.on("data", (chunk) => this.handleStdout(chunk));
    this.child.stderr.on("data", () => {});
    this.child.on("error", (error) => {
      this.failPending(error);
      this.child = null;
      this.startPromise = null;
      this.initialized = false;
    });
    this.child.on("close", () => {
      this.failPending(new Error("Cyna LSP exited unexpectedly."));
      this.child = null;
      this.startPromise = null;
      this.initialized = false;
    });

    await this.sendRequest(LSP_METHODS.initialize, {
      processId: process.pid,
      clientInfo: { name: "cyna-vscode" },
      rootUri: vscode.workspace.workspaceFolders?.[0]?.uri.toString() || null,
      capabilities: {},
    });
    await this.sendNotification(LSP_METHODS.initialized, {});
    this.initialized = true;
  }

  stop() {
    if (this.child) {
      try {
        if (this.initialized) {
          this.sendRequest(LSP_METHODS.shutdown, null).catch(() => {});
          this.sendNotification(LSP_METHODS.exit, {}).catch(() => {});
        }
      } catch {}
      this.child.kill();
    }
    this.failPending(new Error("Cyna LSP stopped."));
    this.child = null;
    this.buffer = Buffer.alloc(0);
    this.initialized = false;
    this.startPromise = null;
  }

  failPending(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  async sendRequest(method, params) {
    const id = this.nextRequestId++;
    const message = { jsonrpc: "2.0", id, method };
    if (params !== undefined) message.params = params;

    const result = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    this.writeMessage(message);
    return result;
  }

  async sendNotification(method, params) {
    const message = { jsonrpc: "2.0", method };
    if (params !== undefined) message.params = params;
    this.writeMessage(message);
  }

  async documentSymbols(document) {
    await this.ensureStarted();
    const result = await this.sendRequest(LSP_METHODS.documentSymbol, {
      textDocument: { uri: document.uri.toString() },
    });
    return Array.isArray(result) ? result.map(reviveDocumentSymbol) : null;
  }

  async hover(document, position) {
    await this.ensureStarted();
    const result = await this.sendRequest(LSP_METHODS.hover, {
      textDocument: { uri: document.uri.toString() },
      position: { line: position.line, character: position.character },
    });
    return result ? reviveHover(result) : null;
  }

  async definition(document, position) {
    await this.ensureStarted();
    const result = await this.sendRequest(LSP_METHODS.definition, {
      textDocument: { uri: document.uri.toString() },
      position: { line: position.line, character: position.character },
    });
    return result ? reviveDefinition(result) : null;
  }

  writeMessage(message) {
    if (!this.child?.stdin.writable) throw new Error("Cyna LSP is not writable.");
    const payload = Buffer.from(JSON.stringify(message), "utf8");
    const header = Buffer.from(`Content-Length: ${payload.length}\r\n\r\n`, "utf8");
    this.child.stdin.write(Buffer.concat([header, payload]));
  }

  handleStdout(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const headerText = this.buffer.slice(0, headerEnd).toString("utf8");
      const lengthMatch = /Content-Length:\s*(\d+)/i.exec(headerText);
      if (!lengthMatch) {
        this.buffer = Buffer.alloc(0);
        return;
      }
      const bodyLength = Number(lengthMatch[1]);
      const messageEnd = headerEnd + 4 + bodyLength;
      if (this.buffer.length < messageEnd) return;

      const body = this.buffer.slice(headerEnd + 4, messageEnd).toString("utf8");
      this.buffer = this.buffer.slice(messageEnd);

      try {
        this.handleMessage(JSON.parse(body));
      } catch {}
    }
  }

  handleMessage(message) {
    if (typeof message.id !== "undefined") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || "Cyna LSP request failed."));
      else pending.resolve(message.result);
      return;
    }

    if (message.method === LSP_METHODS.publishDiagnostics) {
      this.applyDiagnostics(message.params);
    }
  }

  applyDiagnostics(params) {
    if (!params?.uri || !Array.isArray(params.diagnostics)) return;
    const uri = vscode.Uri.parse(params.uri);
    const diagnostics = params.diagnostics.map((item) => {
      const range = new vscode.Range(
        Number(item.range?.start?.line || 0),
        Number(item.range?.start?.character || 0),
        Number(item.range?.end?.line || 0),
        Number(item.range?.end?.character || 1)
      );
      const diagnostic = new vscode.Diagnostic(
        range,
        item.message || "Cyna diagnostic",
        vscode.DiagnosticSeverity.Error
      );
      diagnostic.source = item.source || DIAGNOSTIC_SOURCE;
      return diagnostic;
    });
    this.collection.set(uri, diagnostics);
  }

  reportTransportError(uri, error) {
    this.collection.set(uri, [diagnosticAtStart(error.message || "Unable to communicate with cyna lsp.")]);
  }
}

function reviveDocumentSymbol(item) {
  const symbol = new vscode.DocumentSymbol(
    item?.name || "",
    item?.detail || "",
    Number(item?.kind || vscode.SymbolKind.Object),
    reviveRange(item?.range),
    reviveRange(item?.selectionRange)
  );
  if (Array.isArray(item?.children)) {
    symbol.children = item.children.map(reviveDocumentSymbol);
  }
  return symbol;
}

function reviveRange(range) {
  return new vscode.Range(
    Number(range?.start?.line || 0),
    Number(range?.start?.character || 0),
    Number(range?.end?.line || 0),
    Number(range?.end?.character || 1)
  );
}

function reviveHover(item) {
  const value = item?.contents?.value;
  if (typeof value !== "string") return null;
  const markdown = new vscode.MarkdownString(value);
  return new vscode.Hover(markdown, item.range ? reviveRange(item.range) : undefined);
}

function reviveDefinition(item) {
  if (Array.isArray(item)) return item.map(reviveDefinition).filter(Boolean);
  if (!item?.uri || !item?.range) return null;
  return new vscode.Location(vscode.Uri.parse(item.uri), reviveRange(item.range));
}

function createDefinitionProvider() {
  return {
    async provideDefinition(document, position) {
      if (lspClient?.shouldUseLsp(document)) {
        try {
          const definition = await lspClient.definition(document, position);
          if (definition) return definition;
        } catch {}
      }

      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildResolutionIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      return symbol ? new vscode.Location(symbol.uri || document.uri, symbol.selectionRange) : null;
    },
  };
}

function createHoverProvider() {
  return {
    async provideHover(document, position) {
      if (lspClient?.shouldUseLsp(document)) {
        try {
          const hover = await lspClient.hover(document, position);
          if (hover) return hover;
        } catch {}
      }

      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildResolutionIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      if (!symbol || !symbol.detail) return null;

      const markdown = new vscode.MarkdownString();
      markdown.appendCodeblock(symbol.detail, "cyna");
      if (symbol.documentation) markdown.appendMarkdown(`\n\n${symbol.documentation}`);
      return new vscode.Hover(markdown, reference.range);
    },
  };
}

function createDocumentSymbolProvider() {
  return {
    async provideDocumentSymbols(document) {
      if (lspClient?.shouldUseLsp(document)) {
        try {
          const symbols = await lspClient.documentSymbols(document);
          if (symbols) return symbols;
        } catch {}
      }
      return buildDocumentIndex(document).documentSymbols;
    },
  };
}

function createCompletionProvider() {
  return {
    provideCompletionItems(document, position) {
      const index = buildResolutionIndex(document);
      const items = [];
      const seen = new Set();

      for (const symbol of visibleSymbolsAtPosition(index, position)) {
        if (seen.has(symbol.name)) continue;
        seen.add(symbol.name);
        const item = new vscode.CompletionItem(symbol.name, completionKindForSymbol(symbol.kind));
        item.detail = symbol.detail || "";
        item.sortText = sortTextForSymbol(symbol.kind, symbol.name);
        items.push(item);
      }

      for (const keyword of KEYWORD_COMPLETIONS) {
        if (seen.has(keyword)) continue;
        const item = new vscode.CompletionItem(keyword, vscode.CompletionItemKind.Keyword);
        item.sortText = `z_${keyword}`;
        items.push(item);
      }

      return items;
    },
  };
}

function createDocumentHighlightProvider() {
  return {
    provideDocumentHighlights(document, position) {
      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildDocumentIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      if (!symbol) return null;

      return collectSymbolOccurrences(document, symbol).map(
        (range) =>
          new vscode.DocumentHighlight(
            range,
            range.isEqual(symbol.selectionRange)
              ? vscode.DocumentHighlightKind.Write
              : vscode.DocumentHighlightKind.Read
          )
      );
    },
  };
}

function createReferenceProvider() {
  return {
    provideReferences(document, position) {
      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildDocumentIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      if (!symbol) return null;

      return collectSymbolOccurrences(document, symbol).map((range) => new vscode.Location(document.uri, range));
    },
  };
}

function createRenameProvider() {
  return {
    prepareRename(document, position) {
      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildDocumentIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      return symbol ? symbol.selectionRange : null;
    },

    provideRenameEdits(document, position, newName) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(newName)) {
        throw new Error("Cyna names must match [A-Za-z_][A-Za-z0-9_]*");
      }

      const reference = getWordInfo(document, position);
      if (!reference) return null;

      const index = buildDocumentIndex(document);
      const symbol = resolveSymbol(index, reference.name, position);
      if (!symbol) return null;

      const edit = new vscode.WorkspaceEdit();
      for (const range of collectSymbolOccurrences(document, symbol)) {
        edit.replace(document.uri, range, newName);
      }
      return edit;
    },
  };
}

function scheduleCheck(document) {
  if (!isCynaDocument(document)) return;

  const config = vscode.workspace.getConfiguration("cyna", document.uri);
  if (!config.get("diagnostics.enabled")) {
    collection.delete(document.uri);
    return;
  }

  clearTimer(document.uri);
  timers.set(
    document.uri.toString(),
    setTimeout(() => {
      timers.delete(document.uri.toString());
      checkDocument(document);
    }, CHECK_DEBOUNCE_MS)
  );
}

function clearTimer(uri) {
  const key = uri.toString();
  const timer = timers.get(key);
  if (timer) clearTimeout(timer);
  timers.delete(key);
}

function isCynaDocument(document) {
  return document.languageId === "cyna" && document.uri.scheme === "file";
}

function getWordInfo(document, position) {
  const range = document.getWordRangeAtPosition(position, WORD_PATTERN);
  if (!range) return null;
  return {
    name: document.getText(range),
    range,
  };
}

function checkDocument(document) {
  if (lspClient?.shouldUseLsp(document)) return;

  const command = resolveCompilerCommand(document.uri);
  if (!command) {
    collection.set(document.uri, [
      diagnosticAtStart(
        "Unable to find a Cyna compiler. Set cyna.compiler.command or open the Cyna repository workspace."
      ),
    ]);
    return;
  }

  const child = cp.spawn(command.command, command.args, {
    cwd: command.cwd,
    shell: false,
    windowsHide: true,
  });

  let output = "";
  let spawnFailed = false;
  child.stdout.on("data", (chunk) => {
    output += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    output += chunk.toString();
  });
  child.on("error", (error) => {
    spawnFailed = true;
    collection.set(document.uri, [diagnosticAtStart(error.message)]);
  });
  child.on("close", () => {
    if (spawnFailed) return;
    collection.set(document.uri, parseDiagnostics(document, output));
  });
}

function resolveLspCommand() {
  const workspaceUri = vscode.workspace.workspaceFolders?.[0]?.uri;
  const config = vscode.workspace.getConfiguration("cyna", workspaceUri);
  const configuredCommand = config.get("lsp.command");
  const configuredArgs = config.get("lsp.args");
  const configuredCwd = config.get("lsp.cwd");
  const workspaceFolder = workspaceUri ? vscode.workspace.getWorkspaceFolder(workspaceUri) : null;
  const cwd =
    resolveConfiguredWorkingDirectory(
      configuredCwd,
      workspaceFolder,
      workspaceUri?.fsPath || process.cwd()
    ) ||
    (workspaceFolder ? workspaceFolder.uri.fsPath : process.cwd());

  return {
    command: configuredCommand || resolveWorkspaceCynaCommand(workspaceFolder) || "cyna",
    args: configuredArgs.length > 0 ? configuredArgs : ["lsp"],
    cwd,
  };
}

function resolveCompilerCommand(uri) {
  const config = vscode.workspace.getConfiguration("cyna", uri);
  const configuredCommand = config.get("compiler.command");
  const configuredArgs = config.get("compiler.args");
  const configuredCwd = config.get("compiler.cwd");
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(uri);
  const cwd =
    resolveConfiguredWorkingDirectory(configuredCwd, workspaceFolder, uri.fsPath) ||
    (workspaceFolder ? workspaceFolder.uri.fsPath : path.dirname(uri.fsPath));

  return {
    command: configuredCommand || resolveWorkspaceCynaCommand(workspaceFolder) || "cyna",
    args: expandArgs(configuredArgs.length > 0 ? configuredArgs : ["check", "${file}"], uri.fsPath),
    cwd,
  };
}

function expandArgs(args, file) {
  return args.map((arg) => arg.replaceAll("${file}", file));
}

function resolveWorkspaceCynaCommand(workspaceFolder) {
  if (!workspaceFolder) return null;
  const candidate = path.join(workspaceFolder.uri.fsPath, "zig-out", "bin", process.platform === "win32" ? "cyna.exe" : "cyna");
  return fs.existsSync(candidate) ? candidate : null;
}

function resolveConfiguredWorkingDirectory(configuredCwd, workspaceFolder, file) {
  if (!configuredCwd || typeof configuredCwd !== "string") return null;

  const trimmed = configuredCwd.trim();
  if (!trimmed) return null;

  const expanded = trimmed
    .replaceAll("${file}", file)
    .replaceAll("${fileDirname}", path.dirname(file))
    .replaceAll("${workspaceFolder}", workspaceFolder ? workspaceFolder.uri.fsPath : "");

  return path.isAbsolute(expanded)
    ? expanded
    : workspaceFolder
      ? path.resolve(workspaceFolder.uri.fsPath, expanded)
      : path.resolve(path.dirname(file), expanded);
}

function parseDiagnostics(document, output) {
  const diagnostics = [];
  const lines = output.split(/\r?\n/);

  for (const line of lines) {
    if (!line.trim()) continue;

    const tokenSpanMatch = /^(.*?):(\d+):(\d+):(\d+): error: (.*)$/.exec(line);
    if (tokenSpanMatch) {
      const [, file, rawLine, rawColumn, rawEndColumn, message] = tokenSpanMatch;
      if (!sameFile(file, document.uri.fsPath)) continue;
      const lineIndex = Math.max(0, Number(rawLine) - 1);
      const columnIndex = Math.max(0, Number(rawColumn) - 1);
      const endColumnIndex = Math.max(columnIndex + 1, Number(rawEndColumn) - 1);
      const diagnostic = new vscode.Diagnostic(
        tokenRangeAt(document, lineIndex, columnIndex, endColumnIndex),
        message,
        vscode.DiagnosticSeverity.Error
      );
      diagnostic.source = DIAGNOSTIC_SOURCE;
      diagnostics.push(diagnostic);
      continue;
    }

    const tokenMatch = /^(.*?):(\d+):(\d+): error: (.*)$/.exec(line);
    if (tokenMatch) {
      const [, file, rawLine, rawColumn, message] = tokenMatch;
      if (!sameFile(file, document.uri.fsPath)) continue;
      const lineIndex = Math.max(0, Number(rawLine) - 1);
      const columnIndex = Math.max(0, Number(rawColumn) - 1);
      const diagnostic = new vscode.Diagnostic(
        tokenRangeAt(document, lineIndex, columnIndex, columnIndex + 1),
        message,
        vscode.DiagnosticSeverity.Error
      );
      diagnostic.source = DIAGNOSTIC_SOURCE;
      diagnostics.push(diagnostic);
      continue;
    }

    const pathMatch = /^(.*?): error: (.*)$/.exec(line);
    if (pathMatch) {
      const [, file, message] = pathMatch;
      if (!sameFile(file, document.uri.fsPath)) continue;
      diagnostics.push(diagnosticAtStart(message));
    }
  }

  return diagnostics;
}

function buildDocumentIndex(document) {
  const symbolsByName = new Map();
  const documentSymbols = [];
  const lines = document.getText().split(/\r?\n/);
  let braceDepth = 0;
  let currentStruct = null;
  let currentFunction = null;

  for (let lineNumber = 0; lineNumber < lines.length; lineNumber += 1) {
    const text = lines[lineNumber];
    const trimmed = text.trim();
    if (!trimmed || trimmed.startsWith("//")) {
      braceDepth += braceDelta(text);
      continue;
    }

    if (!currentFunction && !currentStruct) {
      const typeAlias = text.match(/\btype\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+);/);
      if (typeAlias) {
        addSymbol(
          symbolsByName,
          documentSymbols,
          makeSymbol(
            document,
            lineNumber,
            typeAlias[1],
            vscode.SymbolKind.TypeParameter,
            `type ${typeAlias[1]} = ${typeAlias[2].trim()}`
          )
        );
      }

      const declarationMatch = text.match(/\b((?:c\s+)?(?:struct|enum|union)|flags|protocol|interface)\s+([A-Za-z_][A-Za-z0-9_]*)/);
      if (declarationMatch) {
        const declarationKind = declarationSymbolKind(declarationMatch[1]);
        const symbol = makeSymbol(
          document,
          lineNumber,
          declarationMatch[2],
          declarationKind,
          `${declarationMatch[1]} ${declarationMatch[2]}`
        );
        addSymbol(symbolsByName, documentSymbols, symbol);
        currentStruct = { symbol, startDepth: braceDepth };
      }

      const implMatch = text.match(/\bimpl\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*;/);
      if (implMatch) {
        addSymbol(
          symbolsByName,
          documentSymbols,
          makeSymbol(
            document,
            lineNumber,
            implMatch[1],
            vscode.SymbolKind.Interface,
            `impl ${implMatch[1]}: ${implMatch[2]}`
          )
        );
      }

      const globalMatch = text.match(/\b(pub\s+)?(const|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^=]+))?\s*=\s*(.+);/);
      if (globalMatch) {
        const globalType = globalMatch[4] ? globalMatch[4].trim() : inferTypeFromInitializer(globalMatch[5].trim());
        const detail = globalType
          ? `${globalMatch[2]} ${globalMatch[3]}: ${globalType}`
          : `${globalMatch[2]} ${globalMatch[3]}`;
        const documentation = globalMatch[1] ? "Public top-level global" : "Top-level global";
        addSymbol(
          symbolsByName,
          documentSymbols,
          makeSymbol(document, lineNumber, globalMatch[3], vscode.SymbolKind.Variable, detail, documentation)
        );
      }
    }

    const functionMatch = matchFunctionDeclaration(text);
    if (functionMatch) {
      const returnType = functionMatch.returnType || "void";
      const symbol = makeSymbol(
        document,
        lineNumber,
        functionMatch.name,
        vscode.SymbolKind.Function,
        `fn ${functionMatch.name}(${functionMatch.params.trim()}): ${returnType}`
      );
      addSymbol(symbolsByName, documentSymbols, symbol);
      currentFunction = { symbol, startDepth: braceDepth };

      for (const param of parseParams(functionMatch.params)) {
        addScopedSymbol(
          symbolsByName,
          currentFunction.symbol,
          makeSymbol(document, lineNumber, param.name, vscode.SymbolKind.Variable, `${param.name}: ${param.type}`, null, currentFunction.symbol)
        );
      }
    } else if (currentFunction) {
      const localMatch = text.match(/\b(const|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^=]+))?\s*=\s*(.+);/);
      if (localMatch) {
        const localType = localMatch[3] ? localMatch[3].trim() : inferTypeFromInitializer(localMatch[4].trim());
        const detail = localType ? `${localMatch[1]} ${localMatch[2]}: ${localType}` : `${localMatch[1]} ${localMatch[2]}`;
        addScopedSymbol(
          symbolsByName,
          currentFunction.symbol,
          makeSymbol(document, lineNumber, localMatch[2], vscode.SymbolKind.Variable, detail, null, currentFunction.symbol)
        );
      }
    } else if (currentStruct) {
      const fieldMatch = text.match(/^\s*(?:pub\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^;]+);/);
      if (fieldMatch) {
        const field = makeSymbol(
          document,
          lineNumber,
          fieldMatch[1],
          vscode.SymbolKind.Field,
          `${fieldMatch[1]}: ${fieldMatch[2].trim()}`,
          null,
          currentStruct.symbol
        );
        addScopedSymbol(symbolsByName, currentStruct.symbol, field);
      }
    }

    const nextDepth = braceDepth + braceDelta(text);
    if (currentFunction && nextDepth <= currentFunction.startDepth) {
      currentFunction.symbol.range = extendSymbolRange(document, currentFunction.symbol.range, lineNumber);
      currentFunction = null;
    }
    if (currentStruct && nextDepth <= currentStruct.startDepth) {
      currentStruct.symbol.range = extendSymbolRange(document, currentStruct.symbol.range, lineNumber);
      currentStruct = null;
    }
    braceDepth = nextDepth;
  }

  return { symbolsByName, documentSymbols };
}

function buildResolutionIndex(document) {
  const index = buildDocumentIndex(document);
  const symbolsByName = new Map();

  for (const symbol of collectImportedGlobalSymbols(document.uri.fsPath)) {
    pushNamedSymbol(symbolsByName, symbol);
  }
  for (const candidates of index.symbolsByName.values()) {
    for (const symbol of candidates) pushNamedSymbol(symbolsByName, symbol);
  }

  return {
    symbolsByName,
    documentSymbols: index.documentSymbols,
  };
}

function visibleSymbolsAtPosition(index, position) {
  const symbols = [];
  for (const candidates of index.symbolsByName.values()) {
    const visible = candidates.filter((symbol) => isScopedMatch(symbol, position));
    if (visible.length > 0) symbols.push(visible[visible.length - 1]);
  }
  return symbols.sort((a, b) => a.name.localeCompare(b.name));
}

function collectSymbolOccurrences(document, symbol) {
  const scopeRange = symbol.parent ? symbol.parent.range : fullDocumentRange(document);
  const regex = new RegExp(`\\b${escapeRegex(symbol.name)}\\b`, "g");
  const occurrences = [];

  for (let lineNumber = scopeRange.start.line; lineNumber <= scopeRange.end.line; lineNumber += 1) {
    const line = document.lineAt(lineNumber).text;
    let match;
    while ((match = regex.exec(line)) !== null) {
      const start = match.index;
      occurrences.push(new vscode.Range(lineNumber, start, lineNumber, start + symbol.name.length));
    }
  }

  return occurrences;
}

function braceDelta(text) {
  const opens = (text.match(/\{/g) || []).length;
  const closes = (text.match(/\}/g) || []).length;
  return opens - closes;
}

function parseParams(text) {
  if (!text.trim()) return [];
  return splitTopLevel(text, ",")
    .map((part) => part.trim())
    .map((part) => {
      const match = part.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/);
      return match ? { name: match[1], type: match[2].trim() } : null;
    })
    .filter(Boolean);
}

function splitTopLevel(text, separator) {
  const parts = [];
  let start = 0;
  let parenDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  let inString = false;
  let escaped = false;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === "\"") {
        inString = false;
      }
      continue;
    }

    if (ch === "\"") {
      inString = true;
      continue;
    }
    if (ch === "(") parenDepth += 1;
    else if (ch === ")") parenDepth = Math.max(0, parenDepth - 1);
    else if (ch === "[") bracketDepth += 1;
    else if (ch === "]") bracketDepth = Math.max(0, bracketDepth - 1);
    else if (ch === "{") braceDepth += 1;
    else if (ch === "}") braceDepth = Math.max(0, braceDepth - 1);
    else if (ch === separator && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }

  parts.push(text.slice(start));
  return parts;
}

function findMatchingParen(text, openIndex) {
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === "\"") {
        inString = false;
      }
      continue;
    }

    if (ch === "\"") {
      inString = true;
      continue;
    }
    if (ch === "(") depth += 1;
    else if (ch === ")") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }

  return -1;
}

function matchFunctionDeclaration(text) {
  const start = text.search(/\bfn\s+[A-Za-z_][A-Za-z0-9_]*\s*\(/);
  if (start < 0) return null;

  const head = text.slice(start);
  const headMatch = head.match(/^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
  if (!headMatch) return null;

  const name = headMatch[1];
  const openIndex = start + headMatch[0].length - 1;
  const closeIndex = findMatchingParen(text, openIndex);
  if (closeIndex < 0) return null;

  const params = text.slice(openIndex + 1, closeIndex);
  const after = text.slice(closeIndex + 1);
  const returnMatch = after.match(/^\s*(?::\s*([^={]+))?/);
  const returnType = returnMatch && returnMatch[1] ? returnMatch[1].trim() : null;

  return { name, params, returnType };
}

function inferTypeFromInitializer(initializer) {
  if (/^new\s+([A-Za-z_][A-Za-z0-9_]*)\b/.test(initializer)) {
    return `^${initializer.match(/^new\s+([A-Za-z_][A-Za-z0-9_]*)\b/)[1]}`;
  }
  if (/^([A-Z][A-Za-z0-9_]*)\s*\{/.test(initializer)) {
    return initializer.match(/^([A-Z][A-Za-z0-9_]*)\s*\{/)[1];
  }
  if (/^[0-9]+\.[0-9]*$|^[0-9]*\.[0-9]+$/.test(initializer)) return "f64";
  if (/^[0-9]+$/.test(initializer)) return "i32";
  if (/^".*"$/.test(initializer)) return "string";
  if (/^(true|false)$/.test(initializer)) return "bool";
  if (/^none$/.test(initializer)) return "?";
  if (/^(ok|err)\b/.test(initializer)) return "union";
  if (/^\[/.test(initializer)) return "array";
  return null;
}

function makeSymbol(document, lineNumber, name, kind, detail, documentation = null, parent = null) {
  const line = document.lineAt(lineNumber);
  const start = line.text.indexOf(name);
  const selectionRange = new vscode.Range(lineNumber, start, lineNumber, start + name.length);
  const range = new vscode.Range(lineNumber, 0, lineNumber, line.text.length);
  const symbol = new vscode.DocumentSymbol(name, detail || "", kind, range, selectionRange);
  symbol.detail = detail || "";
  symbol.documentation = documentation;
  symbol.parent = parent;
  symbol.children = symbol.children || [];
  symbol.uri = document.uri;
  return symbol;
}

function makeImportedSymbol(filePath, lineNumber, lineText, name, kind, detail, documentation = null) {
  const start = lineText.indexOf(name);
  const selectionRange = new vscode.Range(lineNumber, start, lineNumber, start + name.length);
  const range = new vscode.Range(lineNumber, 0, lineNumber, lineText.length);
  const symbol = new vscode.DocumentSymbol(name, detail || "", kind, range, selectionRange);
  symbol.detail = detail || "";
  symbol.documentation = documentation;
  symbol.parent = null;
  symbol.children = [];
  symbol.uri = vscode.Uri.file(filePath);
  return symbol;
}

function addSymbol(symbolsByName, documentSymbols, symbol) {
  documentSymbols.push(symbol);
  pushNamedSymbol(symbolsByName, symbol);
}

function addScopedSymbol(symbolsByName, parent, symbol) {
  if (parent) parent.children.push(symbol);
  pushNamedSymbol(symbolsByName, symbol);
}

function pushNamedSymbol(symbolsByName, symbol) {
  const list = symbolsByName.get(symbol.name) || [];
  list.push(symbol);
  symbolsByName.set(symbol.name, list);
}

function extendSymbolRange(document, range, lineNumber) {
  const line = document.lineAt(lineNumber);
  return new vscode.Range(range.start.line, range.start.character, lineNumber, line.text.length);
}

function resolveSymbol(index, name, position) {
  const candidates = index.symbolsByName.get(name) || [];
  if (candidates.length === 0) return null;

  const scoped = candidates.filter((symbol) => isScopedMatch(symbol, position));
  return scoped.length > 0 ? scoped[scoped.length - 1] : candidates[0];
}

function completionKindForSymbol(kind) {
  switch (kind) {
    case vscode.SymbolKind.Function:
      return vscode.CompletionItemKind.Function;
    case vscode.SymbolKind.Struct:
      return vscode.CompletionItemKind.Struct;
    case vscode.SymbolKind.Enum:
      return vscode.CompletionItemKind.Enum;
    case vscode.SymbolKind.Interface:
      return vscode.CompletionItemKind.Interface;
    case vscode.SymbolKind.Namespace:
      return vscode.CompletionItemKind.Module;
    case vscode.SymbolKind.Field:
      return vscode.CompletionItemKind.Field;
    case vscode.SymbolKind.Variable:
      return vscode.CompletionItemKind.Variable;
    case vscode.SymbolKind.TypeParameter:
      return vscode.CompletionItemKind.TypeParameter;
    default:
      return vscode.CompletionItemKind.Text;
  }
}

function sortTextForSymbol(kind, name) {
  switch (kind) {
    case vscode.SymbolKind.Variable:
      return `a_${name}`;
    case vscode.SymbolKind.Field:
      return `b_${name}`;
    case vscode.SymbolKind.Function:
      return `c_${name}`;
    case vscode.SymbolKind.Struct:
    case vscode.SymbolKind.Enum:
    case vscode.SymbolKind.Interface:
    case vscode.SymbolKind.Namespace:
    case vscode.SymbolKind.TypeParameter:
      return `d_${name}`;
    default:
      return `y_${name}`;
  }
}

function declarationSymbolKind(keyword) {
  switch (keyword) {
    case "enum":
    case "c enum":
    case "flags":
      return vscode.SymbolKind.Enum;
    case "interface":
      return vscode.SymbolKind.Interface;
    default:
      return vscode.SymbolKind.Struct;
  }
}

function isScopedMatch(symbol, position) {
  if (!symbol.parent) return true;
  return symbol.parent.range.contains(position);
}

function collectImportedGlobalSymbols(fromPath) {
  const symbols = [];
  for (const decl of parseImports(readFileIfPresent(fromPath))) {
    const resolved = resolveImportPath(fromPath, decl.path);
    if (!resolved) continue;
    const source = readFileIfPresent(resolved);
    if (!source) continue;
    if (decl.kind === "namespace") {
      symbols.push(makeImportedModuleSymbol(resolved, decl.localName, decl.path));
      continue;
    }

    const exported = parsePublicExportsFromText(resolved, source);
    for (const item of decl.items) {
      const symbol = exported.get(item.name);
      if (!symbol) continue;
      symbols.push(cloneImportedSymbol(symbol, item.localName || item.name));
    }
  }
  return symbols;
}

function parseImports(source) {
  if (!source) return [];

  const imports = [];
  const lines = source.split(/\r?\n/);
  let braceDepth = 0;
  for (const text of lines) {
    const trimmed = text.trim();
    if (!trimmed || trimmed.startsWith("//")) {
      braceDepth += braceDelta(text);
      continue;
    }
    if (braceDepth === 0) {
      const selectedMatch = text.match(/^\s*import\s*\{\s*([^}]+)\s*\}\s*from\s+(\.?[A-Za-z_][A-Za-z0-9_.]*)\s*;/);
      if (selectedMatch) {
        const items = selectedMatch[1]
          .split(",")
          .map((part) => part.trim())
          .filter(Boolean)
          .map((part) => {
            const aliasMatch = part.match(/^([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/);
            return aliasMatch
              ? { name: aliasMatch[1], localName: aliasMatch[2] || null }
              : null;
          })
          .filter(Boolean);
        imports.push({ kind: "selected", path: selectedMatch[2], items });
      } else {
        const namespaceMatch = text.match(/^\s*import\s+(\.?[A-Za-z_][A-Za-z0-9_.]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;/);
        if (namespaceMatch) {
          imports.push({
            kind: "namespace",
            path: namespaceMatch[1],
            localName: namespaceMatch[2] || basenameForModulePath(namespaceMatch[1]),
          });
        }
      }
    }
    braceDepth += braceDelta(text);
  }
  return imports;
}

function parsePublicExportsFromText(filePath, source) {
  const symbols = new Map();
  const lines = source.split(/\r?\n/);
  let braceDepth = 0;
  let externBlockDepth = null;

  for (let lineNumber = 0; lineNumber < lines.length; lineNumber += 1) {
    const text = lines[lineNumber];
    const trimmed = text.trim();
    if (!trimmed || trimmed.startsWith("//")) {
      braceDepth += braceDelta(text);
      if (externBlockDepth !== null && braceDepth < externBlockDepth) externBlockDepth = null;
      continue;
    }
    if (braceDepth === 0 && /^\s*extern\s*\{/.test(text)) {
      externBlockDepth = braceDepth + 1;
    }
    if (braceDepth === 0 || externBlockDepth !== null) {
      const globalMatch = text.match(/^\s*pub\s+(const|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^=]+))?\s*=\s*(.+);/);
      if (globalMatch) {
        const globalType = globalMatch[3] ? globalMatch[3].trim() : inferTypeFromInitializer(globalMatch[4].trim());
        const detail = globalType ? `${globalMatch[1]} ${globalMatch[2]}: ${globalType}` : `${globalMatch[1]} ${globalMatch[2]}`;
        symbols.set(
          globalMatch[2],
          makeImportedSymbol(
            filePath,
            lineNumber,
            text,
            globalMatch[2],
            vscode.SymbolKind.Variable,
            detail,
            `Imported public global from ${path.basename(filePath)}`
          )
        );
      }

      const functionMatch = matchPublicFunctionDeclaration(text);
      if (functionMatch) {
        const returnType = functionMatch.returnType || "void";
        symbols.set(
          functionMatch.name,
          makeImportedSymbol(
            filePath,
            lineNumber,
            text,
            functionMatch.name,
            vscode.SymbolKind.Function,
            `fn ${functionMatch.name}(${functionMatch.params.trim()}): ${returnType}`,
            `Imported public function from ${path.basename(filePath)}`
          )
        );
      }

      const typeAliasMatch = text.match(/^\s*pub\s+type\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+);/);
      if (typeAliasMatch) {
        symbols.set(
          typeAliasMatch[1],
          makeImportedSymbol(
            filePath,
            lineNumber,
            text,
            typeAliasMatch[1],
            vscode.SymbolKind.TypeParameter,
            `type ${typeAliasMatch[1]} = ${typeAliasMatch[2].trim()}`,
            `Imported public type alias from ${path.basename(filePath)}`
          )
        );
      }

      const declarationMatch = text.match(/^\s*pub\s+((?:c\s+)?(?:struct|enum|union)|flags|protocol|interface)\s+([A-Za-z_][A-Za-z0-9_]*)/);
      if (declarationMatch) {
        symbols.set(
          declarationMatch[2],
          makeImportedSymbol(
            filePath,
            lineNumber,
            text,
            declarationMatch[2],
            declarationSymbolKind(declarationMatch[1]),
            `${declarationMatch[1]} ${declarationMatch[2]}`,
            `Imported public ${declarationMatch[1]} from ${path.basename(filePath)}`
          )
        );
      }
    }
    braceDepth += braceDelta(text);
    if (externBlockDepth !== null && braceDepth < externBlockDepth) externBlockDepth = null;
  }

  return symbols;
}

function resolveImportPath(fromPath, importPath) {
  const fromDir = resolveImportBaseDir(fromPath);
  const normalizedImport = importPath.startsWith(".") ? importPath.slice(1) : importPath;
  const relativePath = normalizedImport.replaceAll(".", path.sep);
  const directFile = path.join(fromDir, `${relativePath}.cy`);
  return fs.existsSync(directFile) ? directFile : null;
}

function resolveImportBaseDir(fromPath) {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(fromPath));
  const workspaceRoot = workspaceFolder ? workspaceFolder.uri.fsPath : null;
  const packageRoot = findPackageRoot(path.dirname(fromPath), workspaceRoot);
  if (packageRoot) {
    const moduleRoot = resolveManifestModuleRoot(packageRoot);
    if (moduleRoot) return moduleRoot;
    const srcDir = path.join(packageRoot, "src");
    if (fs.existsSync(srcDir)) return srcDir;
    return packageRoot;
  }

  if (workspaceRoot) {
    const workspaceSrc = path.join(workspaceRoot, "src");
    if (fs.existsSync(workspaceSrc)) return workspaceSrc;
    return workspaceRoot;
  }

  return path.dirname(fromPath);
}

function findPackageRoot(startDir, workspaceRoot) {
  let current = startDir;
  while (true) {
    if (fs.existsSync(path.join(current, "cyna.toml")) || fs.existsSync(path.join(current, "manifest.toml"))) {
      return current;
    }
    if (workspaceRoot && sameFile(current, workspaceRoot)) break;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}

function resolveManifestModuleRoot(packageRoot) {
  const manifestPath = fs.existsSync(path.join(packageRoot, "cyna.toml"))
    ? path.join(packageRoot, "cyna.toml")
    : fs.existsSync(path.join(packageRoot, "manifest.toml"))
      ? path.join(packageRoot, "manifest.toml")
      : null;
  if (!manifestPath) return null;

  const source = readFileIfPresent(manifestPath);
  if (!source) return null;

  const entryMatch = source.match(/^\s*entry\s*=\s*"([^"]+)"/m);
  if (entryMatch) {
    return path.resolve(packageRoot, path.dirname(entryMatch[1]));
  }

  const srcMatch = source.match(/^\s*src\s*=\s*"([^"]+)"/m);
  if (srcMatch) {
    return path.resolve(packageRoot, srcMatch[1]);
  }

  return null;
}

function basenameForModulePath(modulePath) {
  const parts = modulePath.split(".").filter(Boolean);
  return parts[parts.length - 1];
}

function matchPublicFunctionDeclaration(text) {
  const start = text.search(/^\s*pub\s+(?:(?:extern|export)\s+)?(?:c|asm)(?:\s*\(\s*"[^"]*"\s*\))?\s+fn\s+[A-Za-z_][A-Za-z0-9_]*\s*\(|^\s*pub\s+fn\s+[A-Za-z_][A-Za-z0-9_]*\s*\(/);
  if (start < 0) return null;

  const head = text.slice(start);
  const headMatch = head.match(/^\s*pub\s+(?:(?:(?:extern|export)\s+)?(?:c|asm)(?:\s*\(\s*"[^"]*"\s*\))?\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
  if (!headMatch) return null;

  const name = headMatch[1];
  const openIndex = start + headMatch[0].length - 1;
  const closeIndex = findMatchingParen(text, openIndex);
  if (closeIndex < 0) return null;

  const params = text.slice(openIndex + 1, closeIndex);
  const after = text.slice(closeIndex + 1);
  const returnMatch = after.match(/^\s*(?::\s*([^={]+))?/);
  const returnType = returnMatch && returnMatch[1] ? returnMatch[1].trim() : null;

  return { name, params, returnType };
}

function makeImportedModuleSymbol(filePath, localName, modulePath) {
  const uri = vscode.Uri.file(filePath);
  const selectionRange = new vscode.Range(0, 0, 0, 1);
  const symbol = new vscode.DocumentSymbol(localName, `module ${modulePath}`, vscode.SymbolKind.Namespace, selectionRange, selectionRange);
  symbol.detail = `module ${modulePath}`;
  symbol.documentation = `Imported module namespace from ${path.basename(filePath)}`;
  symbol.parent = null;
  symbol.children = [];
  symbol.uri = uri;
  return symbol;
}

function cloneImportedSymbol(symbol, localName) {
  const cloned = new vscode.DocumentSymbol(localName, symbol.detail || "", symbol.kind, symbol.range, symbol.selectionRange);
  cloned.detail = symbol.detail || "";
  cloned.documentation = symbol.documentation;
  cloned.parent = null;
  cloned.children = [];
  cloned.uri = symbol.uri;
  return cloned;
}

function readFileIfPresent(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
}

function sameFile(a, b) {
  return path.resolve(a) === path.resolve(b);
}

function tokenRangeAt(document, lineIndex, columnIndex, endColumnIndex) {
  const line = document.lineAt(Math.min(lineIndex, document.lineCount - 1));
  const start = Math.min(columnIndex, line.text.length);
  const end = Math.max(start + 1, Math.min(endColumnIndex, line.text.length));
  return new vscode.Range(line.lineNumber, start, line.lineNumber, end);
}

function fullDocumentRange(document) {
  const lastLine = Math.max(0, document.lineCount - 1);
  return new vscode.Range(0, 0, lastLine, document.lineAt(lastLine).text.length);
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function diagnosticAtStart(message) {
  const diagnostic = new vscode.Diagnostic(
    new vscode.Range(0, 0, 0, 1),
    message,
    vscode.DiagnosticSeverity.Error
  );
  diagnostic.source = DIAGNOSTIC_SOURCE;
  return diagnostic;
}

module.exports = {
  activate,
  deactivate,
};
