for name in $(yq '.records[].name' records.yaml); do
  if dig @10.10.69.21 "${name}.kcarterlabs.tech" +short > /dev/null; then
    echo "✅ SUCCESS: ${name}.kcarterlabs.tech resolved! 🎉"
  else
    echo "❌ FAIL: ${name}.kcarterlabs.tech did not resolve. 😢"
  fi
done