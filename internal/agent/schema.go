package agent

import (
	"reflect"
	"strings"
)

const (
	jsonTypeString = "string"
	jsonTypeObject = "object"
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
		return map[string]any{"type": jsonTypeObject}
	}

	properties := make(map[string]any)
	var required []string

	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if field.PkgPath != "" { // Skip unexported fields
			continue
		}

		name, omitempty, skip := parseJSONTag(field)
		if skip {
			continue
		}

		properties[name] = buildFieldProperty(field)
		if !omitempty {
			required = append(required, name)
		}
	}

	schema := map[string]any{
		"type":       jsonTypeObject,
		"properties": properties,
		"required":   required,
	}
	if len(required) == 0 {
		schema["required"] = []string{}
	}

	return schema
}

func parseJSONTag(field reflect.StructField) (name string, omitempty, skip bool) {
	jsonTag := field.Tag.Get("json")
	if jsonTag == "-" {
		return "", false, true
	}

	name = jsonTag
	if commaIdx := strings.Index(jsonTag, ","); commaIdx != -1 {
		name = jsonTag[:commaIdx]
		if strings.Contains(jsonTag[commaIdx+1:], "omitempty") {
			omitempty = true
		}
	}

	if name == "" {
		name = field.Name
	}
	return name, omitempty, false
}

func buildFieldProperty(field reflect.StructField) map[string]any {
	prop := map[string]any{
		"type": goTypeToJSONType(field.Type),
	}

	if description := field.Tag.Get("schema"); description != "" {
		prop["description"] = description
	}

	// Handle arrays
	if field.Type.Kind() == reflect.Slice || field.Type.Kind() == reflect.Array {
		prop["items"] = map[string]any{
			"type": goTypeToJSONType(field.Type.Elem()),
		}
	}
	return prop
}

func goTypeToJSONType(t reflect.Type) string {
	switch t.Kind() {
	case reflect.String:
		return jsonTypeString
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
		return jsonTypeObject
	default:
		return jsonTypeString
	}
}
