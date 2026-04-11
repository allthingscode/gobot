package agent

import (
	"reflect"
	"strings"
)

// DeriveSchema uses reflection to generate a JSON Schema (type: object) from a Go struct.
// It respects 'json' tags for field names and 'schema' tags for descriptions.
// Fields are considered required unless the 'json' tag contains 'omitempty'.
func DeriveSchema(v any) map[string]any {
	t := reflect.TypeOf(v)
	if t.Kind() == reflect.Ptr {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct {
		return map[string]any{"type": "object"}
	}

	properties := make(map[string]any)
	var required []string

	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if field.PkgPath != "" { // Skip unexported fields
			continue
		}

		jsonTag := field.Tag.Get("json")
		if jsonTag == "-" {
			continue
		}

		name := jsonTag
		omitempty := false
		if commaIdx := strings.Index(jsonTag, ","); commaIdx != -1 {
			name = jsonTag[:commaIdx]
			if strings.Contains(jsonTag[commaIdx+1:], "omitempty") {
				omitempty = true
			}
		}

		if name == "" {
			name = field.Name
		}

		description := field.Tag.Get("schema")

		prop := map[string]any{
			"type": goTypeToJSONType(field.Type),
		}
		if description != "" {
			prop["description"] = description
		}

		// Handle arrays
		if field.Type.Kind() == reflect.Slice || field.Type.Kind() == reflect.Array {
			prop["items"] = map[string]any{
				"type": goTypeToJSONType(field.Type.Elem()),
			}
		}

		properties[name] = prop

		if !omitempty {
			required = append(required, name)
		}
	}

	schema := map[string]any{
		"type":       "object",
		"properties": properties,
	}
	if len(required) > 0 {
		schema["required"] = required
	} else {
		schema["required"] = []string{}
	}

	return schema
}

func goTypeToJSONType(t reflect.Type) string {
	switch t.Kind() {
	case reflect.String:
		return "string"
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return "integer"
	case reflect.Float32, reflect.Float64:
		return "number"
	case reflect.Bool:
		return "boolean"
	case reflect.Slice, reflect.Array:
		return "array"
	case reflect.Map, reflect.Struct:
		return "object"
	default:
		return "string"
	}
}
