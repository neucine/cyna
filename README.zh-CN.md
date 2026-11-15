# Cyna

[English](README.md)

Cyna 是一门可以直接与 C 代码交互的系统编程语言。它保留了对内存和底层行为的控制，同时让值的复制、所有权的转移和资源清理更明确。如果你喜欢 C 的直接，又希望代码里的所有权关系更容易看懂，可以从下面的例子开始。

## 快速开始

安装当前版本，并检查安装结果：

```sh
curl -fsSL https://cyna.dev/install.sh | sh
export PATH="$HOME/.cyna/current/bin:$PATH"
cyna version
```

本仓库中的示例可以用 `cyna run examples/milestone_app.cy` 运行。

Windows x64 用户可以在 PowerShell 中运行 `irm https://cyna.dev/install.ps1 | iex`。

想看看编译器生成的中间表示，可以运行：

```sh
cyna build examples/milestone_app.cy --emit-lir
```

平台要求见[构建说明](docs/BUILD.md)。哪些功能已经实现，以[项目状态](docs/STATUS.md)为准。

## 先认识几个设计

- 日常代码优先使用值和容器。需要指针时，`^T` 表示拥有所有权，`&T` 表示借用，`*T` 表示原始指针。
- 需要执行不安全操作时，用 `unchecked` 明确标出边界。
- 与 C 交互时，可以使用 `c struct`、`c union`、`c enum`、`extern c` 和 `export c`。
- 函数可以用 `T!E` 表示可能失败，并用 `throw`、`try` 和 `catch` 处理失败。

想快速了解写法，可以先看[语法速查表](docs/CHEATSHEET.md)；遇到细节问题时再查[语言规范](docs/SPEC.md)。更多示例、限制和工具链说明见[英文 README](README.md)。有问题或建议，欢迎到 [GitHub Issues](https://github.com/neucine/cyna/issues) 交流。
