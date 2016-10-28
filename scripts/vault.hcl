backend "consul" {
  address = "__CONSULMASTER__:8500"
  path = "vault/"
}

listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = 1
}
