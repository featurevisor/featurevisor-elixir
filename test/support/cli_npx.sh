#!/bin/sh
printf '%s\n' CALL "$@" >> calls.log
case "$2" in
  config) printf '%s\n' '{"sets":false}' ;;
  list)
    case "$*" in
      *--tests*) printf '%s\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"smoke","scenario":"smoke","_test":{"source":"tests/smoke.spec.yml","set":null,"entityType":"scenario"},"assertions":[{"description":"ready","_case":{"id":"case-smoke","assertionIndex":0,"matrixIndex":null,"matrixValues":{}},"checks":[{"variable":"marker","operator":"equals","value":"ready"}]}]}]}' ;;
      *--targets*) printf '%s\n' '[{"key":"web"},{"key":"space target"}]' ;;
      *) printf '%s\n' '[]' ;;
    esac ;;
  build)
    printf '%s\n' 'delegated warning' >&2
    printf '%s\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{"checkout":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},"variables":{"marker":{"type":"string","defaultValue":"ready"}}}' ;;
  *) exit 9 ;;
esac
