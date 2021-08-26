# GDHxA
A Godot utility that reads a file of Eskil Steenberg's HxA (pronounced "haxa") format and loads it into a MeshInstance for viewing.
Currently hard-coaded to load the teapot.hxa in the project's root directory, which is the very same one included with HxA itself.
Busted and missing many features atm, but it *kind of* loads teapot.hxa (Godot ArrayMesh needs triangles and I would have to reimplement the triangulation util in GDScript somehow)