# https://help.ente.io/self-hosting/installation/compose
# https://github.com/ente-io/ente/blob/main/server/config/compose.yaml

Can I just self host Ente Auth?

Yes, if you wish, you can self-host the server and use it only for the 2FA auth app. The starter Docker compose will work fine for either Photos or Auth (or both!).

    You currently don't need to configure the S3 object storage (e.g. minio containers) if you're only using your self hosted Ente instance for auth.