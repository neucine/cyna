import { Setting, startup, runtime, parse_bool, parse_positive_usize, parse_non_empty_string, ConfigError } from std.config;
import { env_set, env_unset } from std.process;

fn main(): i32 {
    var threads = startup<usize>("CYNA_CONFIG_TEST_THREADS", 1, parse_positive_usize);
    var tracing = runtime<bool>("CYNA_CONFIG_TEST_TRACING", false, parse_bool);
    var pattern = startup<string>("CYNA_CONFIG_TEST_PATTERN", "abc", parse_non_empty_string);
    assert(threads.get() == 1);
    assert(tracing.get() == false);
    assert(pattern.get() == "abc");
    const absent = threads.load_env() catch (code) {
        assert(false);
        return 1;
    };
    assert(absent == false);
    env_set("CYNA_CONFIG_TEST_THREADS", "4") catch (code) {
        assert(false);
        return 1;
    };
    env_set("CYNA_CONFIG_TEST_TRACING", "yes") catch (code) {
        assert(false);
        return 1;
    };
    const loaded_threads = threads.load_env() catch (code) {
        assert(false);
        return 1;
    };
    const loaded_tracing = tracing.load_env() catch (code) {
        assert(false);
        return 1;
    };
    assert(loaded_threads);
    assert(loaded_tracing);
    assert(threads.get() == 4);
    assert(tracing.get() == true);
    threads.freeze();
    tracing.set(false) catch (code) {
        assert(false);
        return 1;
    };
    assert(tracing.get() == false);
    const invalid = parse_positive_usize("0") catch (code) {
        assert(code == ConfigError.invalid_value);
        return finish_locked(&threads);
    };
    assert(false);
    return 1;
}

fn finish_locked(threads: &Setting<usize>): i32 {
    threads.set(8) catch (code) {
        assert(code == ConfigError.startup_locked);
        env_unset("CYNA_CONFIG_TEST_THREADS") catch (err) {
            assert(false);
            return 1;
        };
        env_unset("CYNA_CONFIG_TEST_TRACING") catch (err) {
            assert(false);
            return 1;
        };
        return 0;
    };
    assert(false);
    return 1;
}
