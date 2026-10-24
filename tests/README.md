# Static checks

From the repository root, run only the requested syntax and well-formedness checks:

```sh
sh -n bootstrap.sh
node --check dsh-web-runner.mjs
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("unraid/dsh.xml")'
```

These checks cover shell parsing, JavaScript syntax, and XML parsing. They do not test startup, NPM registry access, package installation, image builds, or deployment.
