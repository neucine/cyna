package svd

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"text/template"
	"unicode"
)

//go:embed svd.cyna.gotmpl
var templateFile []byte

type Options struct {
	InitialiseFields bool
	EmitFlags        bool
}

type Context struct {
	Device  Device
	Options Options
}

type EnumCase struct {
	Name        string
	Description string
	Value       uint64
}

func Convert(r io.Reader, w io.Writer, options Options) error {
	bytes, err := io.ReadAll(r)

	if err != nil {
		return err
	}

	device := Parse(bytes)
	return Write(w, device, options)
}

func Write(writer io.Writer, device Device, options Options) error {
	tmpl, err := template.New("svd.cyna.gotmpl").Funcs(template.FuncMap{
		"field": safeFieldName,
		"type":  safeTypeName,
		"line": func(c string) string {
			return strings.TrimSpace(regexp.MustCompile(`[ \t]+`).ReplaceAllString(strings.ReplaceAll(c, "\n", " "), " "))
		},
		"join": func(s []string, sep string) string {
			return strings.Join(s, sep)
		},
		"raw": rawType,
		"hex": func(value int) string {
			return fmt.Sprintf("0x%x", value)
		},
		"escape": escapeString,
		"regWrapper": func(access string) string {
			switch strings.ToLower(strings.TrimSpace(access)) {
			case "read-only":
				return "mmio.ReadOnlyReg"
			case "write-only", "writeonce", "write-once":
				return "mmio.WriteOnlyReg"
			default:
				return "mmio.Reg"
			}
		},
		"regType": func(access string, size int, qualifiedType string) string {
			raw := rawType(size)
			switch strings.ToLower(strings.TrimSpace(access)) {
			case "read-only":
				switch raw {
				case "u32":
					return fmt.Sprintf("mmio.Reg32RO<%s>", qualifiedType)
				case "u64":
					return fmt.Sprintf("mmio.Reg64RO<%s>", qualifiedType)
				default:
					return fmt.Sprintf("mmio.ReadOnlyReg<%s, %s>", qualifiedType, raw)
				}
			case "write-only", "writeonce", "write-once":
				switch raw {
				case "u32":
					return fmt.Sprintf("mmio.Reg32WO<%s>", qualifiedType)
				case "u64":
					return fmt.Sprintf("mmio.Reg64WO<%s>", qualifiedType)
				default:
					return fmt.Sprintf("mmio.WriteOnlyReg<%s, %s>", qualifiedType, raw)
				}
			default:
				switch raw {
				case "u32":
					return fmt.Sprintf("mmio.Reg32<%s>", qualifiedType)
				case "u64":
					return fmt.Sprintf("mmio.Reg64<%s>", qualifiedType)
				default:
					return fmt.Sprintf("mmio.Reg<%s, %s>", qualifiedType, raw)
				}
			}
		},
		"registerMetadata": registerMetadataLines,
		"fieldMetadata":    fieldMetadataLines,
		"fieldType": func(peripheral string, register DerivedRegister, field DerivedField) string {
			if len(enumCases(field)) == 0 {
				return fmt.Sprintf("u%d", field.Size)
			}
			return fmt.Sprintf("%s.%s.%s", safeFieldName(peripheral), safeTypeName(register.TypeName), safeTypeName(field.TypeName))
		},
		"enumKind": func(options Options, field DerivedField) string {
			if options.EmitFlags && enumValuesAreFlags(field.Enums, field.Size) {
				return "flags"
			}
			return "enum"
		},
		"enumCases": enumCases,
		"parseEnum": parseEnumValueForTemplate,
	}).Parse(string(templateFile))

	var buffer bytes.Buffer
	err = tmpl.Execute(&buffer, Context{
		Device:  device,
		Options: options,
	})
	if err != nil {
		return err
	}

	output := strings.TrimRight(buffer.String(), "\n") + "\n"
	_, err = io.WriteString(writer, output)
	return err
}

func registerMetadataLines(register DerivedRegister) []string {
	lines := make([]string, 0, 5)
	if metadataAccess(register.Access) != "" {
		lines = append(lines, "SVD access: "+metadataAccess(register.Access))
	}
	if strings.TrimSpace(register.ModifiedWriteValues) != "" {
		lines = append(lines, "SVD modifiedWriteValues: "+strings.TrimSpace(register.ModifiedWriteValues))
	}
	if strings.TrimSpace(register.WriteConstraint) != "" {
		lines = append(lines, "SVD writeConstraint: "+strings.TrimSpace(register.WriteConstraint))
	}
	if strings.TrimSpace(register.ReadAction) != "" {
		lines = append(lines, "SVD readAction: "+strings.TrimSpace(register.ReadAction))
	}
	if strings.TrimSpace(register.ResetValue) != "" {
		lines = append(lines, "SVD resetValue: "+strings.TrimSpace(register.ResetValue))
	}
	if strings.TrimSpace(register.ResetMask) != "" {
		lines = append(lines, "SVD resetMask: "+strings.TrimSpace(register.ResetMask))
	}
	return lines
}

func fieldMetadataLines(field DerivedField) []string {
	lines := make([]string, 0, 4)
	if metadataAccess(field.Access) != "" {
		lines = append(lines, "SVD access: "+metadataAccess(field.Access))
	}
	if strings.TrimSpace(field.ModifiedWriteValues) != "" {
		lines = append(lines, "SVD modifiedWriteValues: "+strings.TrimSpace(field.ModifiedWriteValues))
	}
	if strings.TrimSpace(field.WriteConstraint) != "" {
		lines = append(lines, "SVD writeConstraint: "+strings.TrimSpace(field.WriteConstraint))
	}
	if strings.TrimSpace(field.ReadAction) != "" {
		lines = append(lines, "SVD readAction: "+strings.TrimSpace(field.ReadAction))
	}
	return lines
}

func metadataAccess(access string) string {
	access = strings.TrimSpace(access)
	if access == "" || strings.EqualFold(access, "read-write") {
		return ""
	}
	return access
}

func escapeString(value string) string {
	return strconv.Quote(value)
}

func validEnumValues(values []EnumeratedValue) []EnumeratedValue {
	out := make([]EnumeratedValue, 0, len(values))
	seen := map[uint64]bool{}
	for _, value := range values {
		parsed, ok := parseEnumValue(value.Value)
		if !ok || seen[parsed] {
			continue
		}
		seen[parsed] = true
		out = append(out, value)
	}
	return out
}

func enumCases(field DerivedField) []EnumCase {
	values := validEnumValues(field.Enums)
	if len(values) == 0 {
		return nil
	}
	if field.Size > 8 {
		cases := make([]EnumCase, 0, len(values))
		for _, value := range values {
			parsed, _ := parseEnumValue(value.Value)
			cases = append(cases, EnumCase{
				Name:        value.Name,
				Description: value.Description,
				Value:       parsed,
			})
		}
		sort.Slice(cases, func(i, j int) bool { return cases[i].Value < cases[j].Value })
		return cases
	}

	limit := uint64(1) << field.Size
	byValue := make(map[uint64]EnumCase, len(values))
	for _, value := range values {
		parsed, _ := parseEnumValue(value.Value)
		if parsed >= limit {
			continue
		}
		byValue[parsed] = EnumCase{
			Name:        value.Name,
			Description: value.Description,
			Value:       parsed,
		}
	}
	cases := make([]EnumCase, 0, limit)
	for value := uint64(0); value < limit; value++ {
		if named, ok := byValue[value]; ok {
			cases = append(cases, named)
			continue
		}
		cases = append(cases, EnumCase{
			Name:        fmt.Sprintf("reserved_%d", value),
			Description: "Reserved value",
			Value:       value,
		})
	}
	return cases
}

func rawType(bits int) string {
	switch {
	case bits <= 8:
		return "u8"
	case bits <= 16:
		return "u16"
	case bits <= 32:
		return "u32"
	default:
		return "u64"
	}
}

func enumValuesAreFlags(values []EnumeratedValue, width int) bool {
	values = validEnumValues(values)
	if len(values) == 0 {
		return false
	}
	limit := uint64(1) << min(width, 63)
	for _, value := range values {
		parsed, ok := parseEnumValue(value.Value)
		if !ok {
			return false
		}
		if parsed == 0 {
			continue
		}
		if parsed >= limit || parsed&(parsed-1) != 0 {
			return false
		}
	}
	return true
}

func parseEnumValueForTemplate(raw string) uint64 {
	value, _ := parseEnumValue(raw)
	return value
}

func parseEnumValue(raw string) (uint64, bool) {
	raw = strings.TrimSpace(raw)
	isHex := strings.HasPrefix(raw, "0x") || strings.HasPrefix(raw, "0X")
	if raw == "" || (!isHex && (strings.Contains(raw, "x") || strings.Contains(raw, "X"))) {
		return 0, false
	}
	raw = strings.ReplaceAll(raw, " ", "")
	if strings.Contains(raw, "<<") {
		parts := strings.SplitN(raw, "<<", 2)
		lhs, errA := parseNumber(parts[0])
		rhs, errB := parseNumber(parts[1])
		if errA == nil && errB == nil && rhs < 64 {
			return lhs << rhs, true
		}
		return 0, false
	}
	value, err := parseNumber(raw)
	return value, err == nil
}

func parseNumber(raw string) (uint64, error) {
	raw = strings.TrimSpace(raw)
	raw = strings.Trim(raw, "()")
	raw = strings.ReplaceAll(raw, "_", "")
	if strings.HasPrefix(raw, "0x") || strings.HasPrefix(raw, "0X") {
		return strconv.ParseUint(raw[2:], 16, 64)
	}
	if strings.HasPrefix(raw, "#") {
		return strconv.ParseUint(raw[1:], 2, 64)
	}
	if strings.HasPrefix(raw, "0b") || strings.HasPrefix(raw, "0B") {
		return strconv.ParseUint(raw[2:], 2, 64)
	}
	return strconv.ParseUint(raw, 10, 64)
}

var keywords = map[string]bool{
	"as": true, "break": true, "const": true, "continue": true, "else": true,
	"enum": true, "extern": true, "false": true, "flags": true, "fn": true,
	"for": true, "if": true, "impl": true, "import": true, "in": true,
	"interface": true, "new": true, "none": true, "pub": true, "return": true,
	"struct": true, "test": true, "true": true, "unchecked": true, "union": true,
	"var": true, "void": true, "while": true,
}

func safeTypeName(name string) string {
	return safeIdentCase(name, true)
}

func safeFieldName(name string) string {
	return safeIdentCase(name, false)
}

func safeIdentCase(name string, upper bool) string {
	name = strings.TrimSpace(name)
	if name == "" {
		if upper {
			return "Item"
		}
		return "item"
	}
	name = strings.NewReplacer("[%s]", "", "%s", "", "%d", "", "[", "_", "]", "", "-", "_", " ", "_", "/", "_").Replace(name)
	var out []rune
	capNext := upper
	lastUnderscore := false
	for _, r := range name {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if len(out) == 0 && unicode.IsDigit(r) {
				if upper {
					out = append(out, 'T')
				} else {
					out = append(out, 'v')
				}
			}
			if capNext {
				out = append(out, unicode.ToUpper(r))
			} else {
				out = append(out, unicode.ToLower(r))
			}
			capNext = false
			lastUnderscore = false
		} else if r == '_' {
			if upper {
				capNext = true
			} else if len(out) != 0 && !lastUnderscore {
				out = append(out, '_')
				lastUnderscore = true
			}
		}
	}
	for len(out) > 0 && out[len(out)-1] == '_' {
		out = out[:len(out)-1]
	}
	if len(out) == 0 {
		if upper {
			return "Item"
		}
		return "item"
	}
	ident := string(out)
	if keywords[ident] {
		return ident + "_"
	}
	return ident
}
