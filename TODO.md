- automated upgrades (https://docs.k3s.io/upgrades/automated)
- check if created ingresses match the ones created manually
- order of installataion (dependency between apps)
- confirm if dns records created by external-dns have expected IP
- automated sealed-secrets logic (use: kubeseal --controller-name sealed-secrets <args>)
- add https://github.com/apps/forking-renovate to readme (does not require write access to code)
  - https://docs.renovatebot.com/security-and-permissions/#global-permissions
- confirm if otel-collector-main (3_helm_main.yaml) is required or has duplicated config from other collectors
- argocd default username/password

------------------------------------

K3S_TOKEN=$(/var/lib/rancher/k3s/server/node-token)

home assistant
https://blog.quadmeup.com/2025/04/07/how-to-run-home-assistant-in-kubernetes/

pihole
https://chriskirby.net/highly-available-pi-hole-setup-in-kubernetes-with-secure-dns-over-https-doh/

syncthing
https://steffenmueller4.github.io/2024/04/28/syncthing-on-k3s.html

actual bduget
https://actualbudget.org/docs/advanced/bank-sync/gocardless

velero
https://velero.io/

collabora online (nextcloud integration)
https://artifacthub.io/packages/helm/collabora-online/collabora-online

https://affine.pro/