//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"testing"
)

func TestDeriveSchema(t *testing.T) {
	t.Parallel()
	type Nested struct {
		Val string `json:"val" schema:"Nested value"`
	}

	type TestArgs struct {
		Command    string   `json:"command" schema:"Executable to run"`
		Args       []string `json:"args,omitempty" schema:"Arguments to pass"`
		Count      int      `json:"count" schema:"Number of times"`
		Enabled    bool     `json:"enabled" schema:"Flag"`
		Ratio      float64  `json:"ratio" schema:"Success ratio"`
		Internal   string   `json:"-"`
		unexported string
		NoTag      string
		Optional   string `json:"optional,omitempty" schema:"Optional field"`
		NestedObj  Nested `json:"nested" schema:"Nested object"`
	}

	// Satisfy linter for unused field
	_ = TestArgs{unexported: "hidden"}

	schema := DeriveSchema(TestArgs{})

	if schema["type"] != "object" { //nolint:goconst // test fixture
		t.Errorf("expected type object, got %v", schema["type"])
	}

	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		t.Fatal("properties not found or not a map")
	}

	verifyProperties(t, properties)

	// Check skipped fields
	if _, ok := properties["Internal"]; ok {
		t.Error("Internal field should be skipped")
	}
	if _, ok := properties["unexported"]; ok {
		t.Error("unexported field should be skipped")
	}

	verifyRequired(t, schema)
}

type expectedProp struct {
	name        string
	jsonType    string
	description string
}

func verifyProperties(t *testing.T, properties map[string]any) {
	t.Helper()
	expectedProps := []expectedProp{
		{"command", "string", "Executable to run"},
		{"args", "array", "Arguments to pass"},
		{"count", "integer", "Number of times"},
		{"enabled", "boolean", "Flag"},
		{"ratio", "number", "Success ratio"},
		{"NoTag", "string", ""},
		{"optional", "string", "Optional field"},
		{"nested", "object", "Nested object"},
	}

	for _, ep := range expectedProps {
		prop, ok := properties[ep.name].(map[string]any)
		if !ok {
			t.Errorf("property %s not found", ep.name)
			continue
		}
		if prop["type"] != ep.jsonType {
			t.Errorf("property %s: expected type %s, got %s", ep.name, ep.jsonType, prop["type"])
		}
		if ep.description != "" && prop["description"] != ep.description {
			t.Errorf("property %s: expected description %s, got %s", ep.name, ep.description, prop["description"])
		}
		if ep.jsonType == "array" {
			items, ok := prop["items"].(map[string]any)
			if !ok {
				t.Errorf("property %s: items not found", ep.name)
			} else if items["type"] != "string" { //nolint:goconst // test fixture
				t.Errorf("property %s: expected items type string, got %s", ep.name, items["type"])
			}
		}
	}
}

func verifyRequired(t *testing.T, schema map[string]any) {
	t.Helper()
	// Check required fields
	required, ok := schema["required"].([]string)
	if !ok {
		t.Fatal("required fields not found or not a slice")
	}

	requiredMap := make(map[string]bool)
	for _, r := range required {
		requiredMap[r] = true
	}

	shouldBeRequired := []string{"command", "count", "enabled", "ratio", "NoTag", "nested"}
	for _, r := range shouldBeRequired {
		if !requiredMap[r] {
			t.Errorf("field %s should be required", r)
		}
	}

	shouldNotBeRequired := []string{"args", "optional"}
	for _, r := range shouldNotBeRequired {
		if requiredMap[r] {
			t.Errorf("field %s should not be required", r)
		}
	}
}

func TestDeriveSchemaPtr(t *testing.T) {
	t.Parallel()
	type S struct {
		F string `json:"f"`
	}
	schema := DeriveSchema(&S{})
	if schema["type"] != "object" {
		t.Error("expected object")
	}
	props := schema["properties"].(map[string]any)
	if _, ok := props["f"]; !ok {
		t.Error("expected property f")
	}
}

func TestDeriveSchemaNonStruct(t *testing.T) {
	t.Parallel()
	schema := DeriveSchema("string")
	if schema["type"] != "object" {
		t.Error("expected object for non-struct")
	}
}
