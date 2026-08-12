{{/*
Resolve a generated secret value, returning a base64-encoded string suitable
for a Secret `data:` field. Precedence: explicit value > existing in-cluster
value > random.

The in-cluster lookup only succeeds during `helm install`/`helm upgrade`;
under `helm template` (e.g. ArgoCD), it returns empty, so an explicit value is
the only way to keep a value stable across GitOps renders.

Args (dict):
  ctx        - root context (.)
  value      - explicit plaintext value ("" to fall back)
  secretName - name of the Secret to look up for preservation
  key        - data key within that Secret
  length     - length of the random fallback
*/}}
{{- define "adminapp.resolveSecret" -}}
{{- if .value -}}
{{- .value | b64enc -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secretName -}}
{{- if and $existing $existing.data (index $existing.data .key) -}}
{{- index $existing.data .key -}}
{{- else -}}
{{- randAlphaNum (.length | int) | b64enc -}}
{{- end -}}
{{- end -}}
{{- end -}}
