#!/bin/bash
dir=(ls -d */)
for i in ${dir[@]}
do
    echo $i
    cd $i
    cp ../.npmrc .
    npm publish --registry=http://jenkins.zkturing.com:8081/nexus/content/repositories/npm-pubile/
    cd ..
done