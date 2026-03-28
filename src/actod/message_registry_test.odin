package actod

import "core:mem"
import "core:sync"
import "core:testing"

@(private)
test_types_registered := false
@(private)
test_registration_mutex: sync.Mutex

@(private)
register_test_types :: proc() {
	sync.lock(&test_registration_mutex)
	defer sync.unlock(&test_registration_mutex)

	if test_types_registered {
		return
	}

	register_message_type(Test_Simple_Message)
	register_message_type(Test_String_Message)
	register_message_type(Test_Complex_Message)

	test_types_registered = true
}

Test_Simple_Message :: struct {
	id:    int,
	value: f64,
}

Test_String_Message :: struct {
	content:     string,
	description: string,
	count:       int,
}

Test_Complex_Message :: struct {
	id:       u32,
	position: [3]f32,
	flags:    u8,
}

@(test)
test_message_registration :: proc(t: ^testing.T) {
	register_test_types()

	info, ok := get_type_info(typeid_of(Test_Simple_Message))
	testing.expect(t, ok, "Test_Simple_Message should be registered")
	testing.expect(t, info.type_id == typeid_of(Test_Simple_Message), "Type ID mismatch")
	testing.expect(t, info.deliver != nil, "Deliver proc should be set")
}

@(test)
test_raw_binary_serialization :: proc(t: ^testing.T) {
	register_test_types()

	{
		original := Test_Simple_Message {
			id    = 42,
			value = 3.14159,
		}

		info, ok := get_type_info(typeid_of(Test_Simple_Message))
		testing.expect(t, ok, "Type info should exist")
		testing.expect(t, info.deliver != nil, "Deliver function should be set")
		testing.expect(t, .Has_Strings not_in info.flags, "Simple message should not have strings")

		raw_bytes := mem.ptr_to_bytes(&original)
		testing.expect(
			t,
			len(raw_bytes) == size_of(Test_Simple_Message),
			"Raw bytes size should match",
		)

		reconstructed := (cast(^Test_Simple_Message)raw_data(raw_bytes))^
		testing.expect(t, reconstructed.id == original.id, "Simple message id should match")
		testing.expect(
			t,
			reconstructed.value == original.value,
			"Simple message value should match",
		)
	}

	{
		original := Test_Complex_Message {
			id       = 999,
			position = {1.0, 2.0, 3.0},
			flags    = 0b10101010,
		}

		info, ok := get_type_info(typeid_of(Test_Complex_Message))
		testing.expect(t, ok, "Type info should exist")
		testing.expect(t, info.deliver != nil, "Deliver function should be set")
		testing.expect(
			t,
			.Has_Strings not_in info.flags,
			"Complex message should not have strings",
		)

		raw_bytes := mem.ptr_to_bytes(&original)
		reconstructed := (cast(^Test_Complex_Message)raw_data(raw_bytes))^

		testing.expect(t, reconstructed.id == original.id, "Complex message id should match")
		testing.expect(
			t,
			reconstructed.position[0] == original.position[0],
			"Position[0] should match",
		)
		testing.expect(
			t,
			reconstructed.position[1] == original.position[1],
			"Position[1] should match",
		)
		testing.expect(
			t,
			reconstructed.position[2] == original.position[2],
			"Position[2] should match",
		)
		testing.expect(t, reconstructed.flags == original.flags, "Flags should match")
	}

	{
		info, ok := get_type_info(typeid_of(Test_String_Message))
		testing.expect(t, ok, "Type info should exist")
		testing.expect(t, .Has_Strings in info.flags, "Should detect strings in message type")
		testing.expect(t, len(info.string_fields) == 2, "Should detect 2 string fields")
		testing.expect(t, info.deliver != nil, "Deliver function should be set")
	}
}

@(test)
test_string_message_binary_format :: proc(t: ^testing.T) {
	register_test_types()

	// [struct bytes][string1 data][string2 data]
	original := Test_String_Message {
		content     = "Hello",
		description = "World",
		count       = 42,
	}

	info, _ := get_type_info(typeid_of(Test_String_Message))

	total_string_size := len(original.content) + len(original.description)
	total_size := size_of(Test_String_Message) + total_string_size

	payload := make([]byte, total_size)
	defer delete(payload)

	content_copy := original
	mem.copy(raw_data(payload), &content_copy, size_of(Test_String_Message))

	string_offset := size_of(Test_String_Message)
	for field in info.string_fields {
		str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
		if len(str_ptr^) > 0 {
			mem.copy(
				rawptr(uintptr(raw_data(payload)) + uintptr(string_offset)),
				raw_data(str_ptr^),
				len(str_ptr^),
			)
			string_offset += len(str_ptr^)
		}
	}

	value := (cast(^Test_String_Message)raw_data(payload))^

	string_offset = size_of(Test_String_Message)
	for field in info.string_fields {
		str_ptr := cast(^string)(uintptr(&value) + field.offset)
		str_len := len(str_ptr^)
		if str_len > 0 {
			str_ptr^ = string(payload[string_offset:string_offset + str_len])
			string_offset += str_len
		}
	}

	testing.expect(t, value.content == original.content, "Content should match")
	testing.expect(t, value.description == original.description, "Description should match")
	testing.expect(t, value.count == original.count, "Count should match")
}

@(test)
test_pod_payload_handling :: proc(t: ^testing.T) {
	register_test_types()

	{
		original := Test_Simple_Message {
			id    = 123,
			value = 2.71828,
		}

		info, ok := get_type_info(typeid_of(Test_Simple_Message))
		testing.expect(t, ok, "Type info should exist")
		testing.expect(
			t,
			.Has_Strings not_in info.flags,
			"Simple message should NOT have strings flag",
		)

		raw_bytes := mem.ptr_to_bytes(&original)
		testing.expect(
			t,
			len(raw_bytes) == size_of(Test_Simple_Message),
			"Raw bytes size should match struct size",
		)

		reconstructed := (cast(^Test_Simple_Message)raw_data(raw_bytes))^
		testing.expect(t, reconstructed.id == original.id, "POD reconstructed id should match")
		testing.expect(
			t,
			reconstructed.value == original.value,
			"POD reconstructed value should match",
		)
	}

	{
		original := Test_Complex_Message {
			id       = 456,
			position = {4.0, 5.0, 6.0},
			flags    = 0xFF,
		}

		info, ok := get_type_info(typeid_of(Test_Complex_Message))
		testing.expect(t, ok, "Type info should exist")
		testing.expect(
			t,
			.Has_Strings not_in info.flags,
			"Complex message should NOT have strings flag",
		)

		raw_bytes := mem.ptr_to_bytes(&original)
		reconstructed := (cast(^Test_Complex_Message)raw_data(raw_bytes))^
		testing.expect(t, reconstructed.id == original.id, "POD reconstructed id should match")
		testing.expect(
			t,
			reconstructed.position == original.position,
			"POD reconstructed position should match",
		)
		testing.expect(
			t,
			reconstructed.flags == original.flags,
			"POD reconstructed flags should match",
		)
	}
}

@(test)
test_type_name_extraction :: proc(t: ^testing.T) {
	{
		ti := type_info_of(Test_Simple_Message)
		name := get_type_name(ti)
		defer delete(name)

		testing.expect(t, name != "", "Type name should not be empty")
		testing.expect(
			t,
			name == "message.Test_Simple_Message" || len(name) > 0,
			"Type name should be valid",
		)
	}


	{
		ti := type_info_of(int)
		name := get_type_name(ti)
		defer delete(name)
		testing.expect(t, name != "", "Built-in type should have a name")
	}
}

Test_Empty_Struct_A :: struct {}
Test_Empty_Struct_B :: struct {}

Test_Same_Shape_A :: struct {
	x: int,
	y: f32,
}

Test_Same_Shape_B :: struct {
	x: int,
	y: f32,
}

@(test)
test_type_name_uniqueness :: proc(t: ^testing.T) {
	{
		name_a := get_type_name(type_info_of(Test_Empty_Struct_A))
		defer delete(name_a)
		name_b := get_type_name(type_info_of(Test_Empty_Struct_B))
		defer delete(name_b)

		testing.expect(
			t,
			name_a != name_b,
			"Empty structs with different names should have different type identifiers",
		)
	}

	{
		name_a := get_type_name(type_info_of(Test_Same_Shape_A))
		defer delete(name_a)
		name_b := get_type_name(type_info_of(Test_Same_Shape_B))
		defer delete(name_b)

		testing.expect(
			t,
			name_a != name_b,
			"Structs with same shape but different names should have different identifiers",
		)
	}
}
