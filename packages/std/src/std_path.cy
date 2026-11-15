pub extern c fn join(parts: []const string): string;
pub extern c fn basename(path: string): string;
pub extern c fn dirname(path: string): string;
pub extern c fn extension(path: string): ?string;
pub extern c fn stem(path: string): string;
pub extern c fn is_absolute(path: string): bool;
