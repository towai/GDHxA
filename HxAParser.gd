extends Node

#	Godot utility to read an HxA file and try to put it into a MeshInstance
# This almost works but I'd have to triangulate the mesh first to get Godot to understand
# the faces, and no image data parsing currently exists
# Data reading functions need to be generalized as well but I was more concerned with
# getting this into a semi-working state tonight

const HXA_MAGIC_NUMBER = 0x00_41_78_48 #"HxA"
enum HXANodeType {
	HXA_NT_META_ONLY = 0,	# node only containing meta data.
	HXA_NT_GEOMETRY = 1,	# node containing a geometry mesh, and meta data.
	HXA_NT_IMAGE = 2,		# node containing a 1D, 2D, 3D, or Cube image, and meta data.
	HXA_NT_COUNT = 3,		# the number of different nodes that can be stored in the file.
}
enum HXALayerDataType {
	HXA_LDT_UINT8 = 0,	#/* 8bit unsigned integer, */
	HXA_LDT_INT32 = 1,	#/* 32bit signed integer */
	HXA_LDT_FLOAT = 2,	#/* 32bit IEEE 754 floating point value */
	HXA_LDT_DOUBLE = 3,	#/* 64bit IEEE 754 floating point value */
	HXA_LDT_COUNT = 4,	#/* number of types supported by layers */
}
enum HXAImageType {
	HXA_IT_CUBE_IMAGE = 0,	#/* 6 sided qube, in the order of: +x, -x, +y, -y, +z, -z. */
	HXA_IT_1D_IMAGE = 1,	#/* One dimentional pixel data. */
	HXA_IT_2D_IMAGE = 2,	#/* Two dimentional pixel data. */
	HXA_IT_3D_IMAGE = 3,	#/* Three dimentional pixel data. */
}
enum HXAMetaDataType {
	HXA_MDT_INT64 = 0,
	HXA_MDT_DOUBLE = 1,
	HXA_MDT_NODE = 2,
	HXA_MDT_TEXT = 3,
	HXA_MDT_BINARY = 4,
	HXA_MDT_META = 5,
	HXA_MDT_COUNT = 6
}

class HxANode:
	var HXAMeta : Dictionary
	var type : int
	var meta_count : int
	var vertex_count : int
	var vertex_stack = HxALayerStack.new()
	var edge_corner_count : int
	var corner_stack = HxALayerStack.new()
	var edge_stack   = HxALayerStack.new()
	var face_stack   = HxALayerStack.new()

class HxALayerStack:
	var layer_count : int
	var layers := []

class HxALayer:
	var name := ""
	var components : int
	var type : int # HXALayerDataType
	var data := []

class HxAFile:
	extends File
	var version : int
	var node_count : int
	var node_array := []

onready var HxAData = HxAFile.new()
onready var array_mesh : ArrayMesh = $MeshInstance.mesh


# Helper func
const MAX_31B = 1 << 31
const MAX_32B = 1 << 32

func unsigned32_to_signed(unsigned):
	return (unsigned + MAX_31B) % MAX_32B - MAX_31B


func _ready():
	var err = HxAData.open("res://teapot.hxa",File.READ)
	print(err)
	
	var read = _read_HxA_header()
	if !read: print("Something went wrong in header read; Don't continue")
	# Node array comes next, teapot.hxa only has 1 node
	for i in HxAData.node_count:
		print("Read node %d" % i)
		read = _read_HxA_node()
		if !read: print("Something went wrong in node read %d; Don't continue" % i)
	
	var arrays := []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = HxAData.node_array[0].vertex_stack.layers[0].data
	arrays[ArrayMesh.ARRAY_INDEX] = HxAData.node_array[0].corner_stack.layers[0].data as PoolIntArray
	
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	

func _read_HxA_header() -> bool:
	var check = null
	check = HxAData.get_32()
	if !(check == HXA_MAGIC_NUMBER):
		print("Bad header, is this even an HxA")
		return false
	
	HxAData.version  = HxAData.get_32() # uint8 but gets stored with sizeof(uint32)
	HxAData.node_count = HxAData.get_32()
	print("HxA ver %d with %d nodes" % [HxAData.version,HxAData.node_count])
	return true 


func _read_HxA_node() -> bool:
	var node = HxANode.new()
	HxAData.node_array.append(node)
	# We can assume our pointer is at the start of the node
	node.type = HxAData.get_8()
	print("Node is of type %d" % node.type)
	
	node.meta_count = HxAData.get_32()
	print("%d meta pairs:" % node.meta_count)
	var read = _read_node_meta(node)
	if !read:
		print("Something went wrong in metadata read")
		return false
	
	# Next up: content
	match node.type:
		HXANodeType.HXA_NT_META_ONLY: pass
		HXANodeType.HXA_NT_GEOMETRY:
			read = _read_HxA_geometry(node)
			if !read:
				print("Bad geom read")
				return false
		HXANodeType.HXA_NT_IMAGE:
			read = _read_HxA_image(node)
			if !read:
				print("Bad image read")
				return false
		_:
			print("Invalid node type")
			return false
	
	return true


func _read_node_meta(node:HxANode) -> bool:
	for i in node.meta_count:
		var key_length = HxAData.get_8()
		var key : String = HxAData.get_buffer(key_length).get_string_from_utf8()
		var meta_type = HxAData.get_8()
		var array_length = HxAData.get_32()
		var arr = []
		
		match meta_type:
			HXAMetaDataType.HXA_MDT_INT64:
				for j in array_length:
					var value = HxAData.get_64()
					
					# Bools are apparently stored as int64s of a signature so we need to do a detective work
					var mask = 0x7f_ff_ff_ff_ff_ff_ff_00 # godot doesn't like numbers this high so we throw away the top bit
					var magic = 0x7f_ff_ff_ff_85_85_85_00
					
					var masked_value = value & mask
					if masked_value == magic:
						value = (value & 0xff) as bool # If we don't use parens the parser thinks it's & (0xff as bool)
					
					arr.append(value)
				
			HXAMetaDataType.HXA_MDT_TEXT: # untested
				arr.append(HxAData.get_buffer(array_length)) # Text length is stored in array_length. Single text value per key
			_:
				if meta_type >= HXAMetaDataType.HXA_MDT_COUNT:
					print("Invalid metadata type")
					return false
				print("MDT not supported yet")
		node.HXAMeta[key] = arr
	print(node.HXAMeta)
	print("Done reading node metadata")
	
	return true


func _read_HxA_geometry(node:HxANode) -> bool:
	# Assume we're at the start of the geometry struct
	node.vertex_count = HxAData.get_32()
	
#	node.vertex_stack = HxALayerStack.new()
	node.vertex_stack.layer_count = HxAData.get_32()
	
	for i in node.vertex_stack.layer_count:
		var layer = HxALayer.new()
		node.vertex_stack.layers.append(layer)
		
		var namelen = HxAData.get_8()
		layer.name = HxAData.get_buffer(namelen).get_string_from_utf8()
		
		layer.components = HxAData.get_8()
		layer.type = HxAData.get_8()
		
		
		match layer.name:
			"vertex":
				for v in node.vertex_count:
					var vert = Vector3()
					match layer.type:
						HXALayerDataType.HXA_LDT_DOUBLE:
							vert.x = HxAData.get_double()
							vert.y = HxAData.get_double()
							vert.z = HxAData.get_double()
						HXALayerDataType.HXA_LDT_FLOAT:
							vert.x = HxAData.get_float()
							vert.y = HxAData.get_float()
							vert.z = HxAData.get_float()
						_:
							if layer.type >= HXALayerDataType.HXA_LDT_COUNT:
								print("Invalid layer datatype %d" % layer.type)
								return false
							print("Don't know what to do with layer datatype %d" % layer.type)
					layer.data.append(vert)
			_:
				print("Don't know what to do with this layer : %s" % layer.name)
				return false
	
	node.edge_corner_count = HxAData.get_32()
	print(node.edge_corner_count)
	node.corner_stack.layer_count = HxAData.get_32()
	
	for i in node.corner_stack.layer_count:
		var layer = HxALayer.new()
		node.corner_stack.layers.append(layer)
		
		var namelen = HxAData.get_8()
		layer.name = HxAData.get_buffer(namelen).get_string_from_utf8()
		
		layer.components = HxAData.get_8()
		layer.type = HxAData.get_8()
		
		for j in node.edge_corner_count:
			var value = unsigned32_to_signed(HxAData.get_32())
			value = abs(value) + (value >> 31) # Face ends are -1 - index
			layer.data.append(value)
			
		
	
	return true


func _read_HxA_image(node) -> bool: return false # yet to implement
