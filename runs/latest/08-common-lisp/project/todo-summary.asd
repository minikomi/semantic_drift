(asdf:defsystem "todo-summary"
  :version "1.0.0"
  :serial t
  :depends-on ("dexador" "yason")
  :components ((:file "src/package")
               (:file "src/main")))
