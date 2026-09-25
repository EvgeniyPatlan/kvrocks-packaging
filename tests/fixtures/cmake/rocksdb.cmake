include(cmake/utils.cmake)

FetchContent_DeclareGitHubWithMirror(rocksdb
  facebook/rocksdb v11.8.1
  MD5=e28ce50253c2f30fa789fee7b2381c63
)
