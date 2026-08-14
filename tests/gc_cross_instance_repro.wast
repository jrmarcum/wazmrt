(module $A
  (type $ta (struct (field i32)))
  (global (export "g") anyref (struct.new $ta (i32.const 111)))
)
(register "A" $A)

(module $B
  (type $tb (struct (field i32)))
  (global $fromA (import "A" "g") anyref)
  (global $mine (mut anyref) (ref.null any))
  (func (export "seed") (global.set $mine (struct.new $tb (i32.const 222))))
  (func (export "readA") (result i32)
    (struct.get $tb 0 (ref.cast (ref $tb) (global.get $fromA))))
)
(assert_return (invoke $B "seed"))
(assert_return (invoke $B "readA") (i32.const 111))
