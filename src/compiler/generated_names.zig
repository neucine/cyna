/// Compiler-generated names are presentation and linkage details only. Semantic
/// decisions must use explicit identities carried beside them.
pub const test_function_prefix = "__cyna_test_";
pub const closure_environment_local = "__cyna_env";
pub const closure_environment_type_prefix = "__cyna_closure_env_";
pub const arrow_callable_type = "__cyna_arrow_callable";
pub const arrow_adapter_prefix = "__cyna_arrow_adapter_";
pub const c_abi_adapter_prefix = "__cyna_c_abi_adapter_";
/// Declared-contract stand-ins for generic binder method uses lowered at a
/// definition site, where no concrete witness exists yet.
pub const generic_contract_prefix = "__cyna_generic_contract_";
pub const anonymous_argument_prefix = "__cyna_arg_";
pub const anonymous_function_prefix = "__cyna_fn_expr_";
pub const thread_boxed_trampoline_prefix = "__cyna_thread_boxed_trampoline_";
pub const task_group_trampoline_prefix = "__cyna_task_group_trampoline_";
pub const function_symbol_prefix = "cyna_fn_";
pub const global_symbol_prefix = "cyna_global_";
pub const c_abi_symbol_prefix = "cyna_";
