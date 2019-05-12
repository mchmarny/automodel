events:
	bin/eventmaker --project=${GCP_PROJECT} --region=us-central1 --registry=automodel-reg \
		--device=automodel-device-1 --ca=root-ca.pem --key=device1-private.pem \
		--src=automodel-client --freq=2s --metric=utilization --range=0.01-2.00

