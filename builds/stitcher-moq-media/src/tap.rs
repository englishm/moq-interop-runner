//! TAP version 14 output: the test point per scenario the harness counts, the optional
//! subtest block that names the check that failed, and the YAML diagnostics block.

use serde_json::Value;

/// One oracle check, reported as a TAP subtest point.
#[derive(Debug, Clone)]
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

impl Check {
    pub fn new(name: &'static str, ok: bool, detail: impl Into<String>) -> Self {
        Self {
            name,
            ok,
            detail: detail.into(),
        }
    }
}

/// Print the subtest block for `test`: TAP 14 nests it, indented four spaces, before the
/// parent test point. The harness skips indented lines, so only the parent is counted.
pub fn print_subtests(test: &str, checks: &[Check]) {
    if checks.is_empty() {
        return;
    }
    println!("# Subtest: {}", test);
    println!("    1..{}", checks.len());
    for (i, check) in checks.iter().enumerate() {
        let status = if check.ok { "ok" } else { "not ok" };
        if check.detail.is_empty() {
            println!("    {} {} - {}", status, i + 1, check.name);
        } else {
            println!(
                "    {} {} - {} ({})",
                status,
                i + 1,
                check.name,
                check.detail.replace('\n', " ")
            );
        }
    }
}

/// Print a YAML diagnostics block (two-space indented, `---` … `...`) from a JSON tree.
/// Strings are always quoted so YAML never reinterprets them.
pub fn print_yaml(diag: &Value) {
    println!("  ---");
    if let Value::Object(map) = diag {
        for (key, value) in map {
            print_entry(key, value, 1);
        }
    }
    println!("  ...");
}

fn indent(level: usize) -> String {
    "  ".repeat(level)
}

fn print_entry(key: &str, value: &Value, level: usize) {
    match value {
        Value::Object(map) if map.is_empty() => println!("{}{}: {{}}", indent(level), key),
        Value::Object(map) => {
            println!("{}{}:", indent(level), key);
            for (k, v) in map {
                print_entry(k, v, level + 1);
            }
        }
        Value::Array(items) if items.is_empty() => println!("{}{}: []", indent(level), key),
        Value::Array(items) => {
            println!("{}{}:", indent(level), key);
            for item in items {
                match item {
                    Value::Object(map) => {
                        let mut first = true;
                        for (k, v) in map {
                            if first {
                                print!("{}- ", indent(level + 1));
                                print_inline(k, v, level + 2);
                                first = false;
                            } else {
                                print_entry(k, v, level + 2);
                            }
                        }
                    }
                    other => println!("{}- {}", indent(level + 1), scalar(other)),
                }
            }
        }
        other => println!("{}{}: {}", indent(level), key, scalar(other)),
    }
}

fn print_inline(key: &str, value: &Value, level: usize) {
    match value {
        Value::Object(_) | Value::Array(_) => {
            println!("{}:", key);
            if let Value::Object(map) = value {
                for (k, v) in map {
                    print_entry(k, v, level);
                }
            }
        }
        other => println!("{}: {}", key, scalar(other)),
    }
}

fn scalar(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => quote(s),
        Value::Object(_) | Value::Array(_) => quote(&value.to_string()),
    }
}

/// A double-quoted YAML scalar.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
