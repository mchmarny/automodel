# automodel

BigQuery automatic model rebuild based on r2 score deviation

To demo automodel usage in IOT use-cases we will need a stream of events on our PubSub topic. For this we will use `iot-event-maker`. The complete walkthrough the IOT Core registry and device setup is outline here: https://github.com/mchmarny/iot-event-maker

## Setup

For purposes of `automodel` demo however we are going to simply run the one-time setup command and, assuming everything works, we will then run the event generation command which will send the mocked up events to our topic.

```shell
bin/setup
```

Should result in output similar to this

```shell
Setting up PubSub...
Created topic [projects/PROJECT_ID/topics/automodel-event].
Created topic [projects/PROJECT_ID/topics/automodel-event-state].
Setting up BigQuery...
Dataset 'PROJECT_ID:automodel' successfully created.
Created s9-demo.automodel.event
Setting up Dataflow...
name: automodel-bq-pump
projectId: PROJECT_ID
type: JOB_TYPE_STREAMING
Setting up IOT Core...
Generating a 2048 bit RSA private key
writing new private key to 'device1-private.pem'
Created registry [automodel-reg].
Created device [automodel-device-1].
```

## Run

To stream mocked events to the new IOT Core device run the `eventmaker` utility. Besides references to the IOT Core resources we created in setup, there are a few demo-specific parameters worth explaining:

* `--src` - Unique name of the device from which you are sending events. This is used to identify the specific sender of events in case you are running multiple clients. For this demo we will use something simple like `automodel-client`
* `--metric` - Name of the metric to generate that will be used as `label` in the sent event (e.g. `utilization`)
* `--range` - Range of the random data points that will be generated for the above defined metric (e.g. `0.01-2.00` which means floats between `0.01` and `2.00`)
* `--freq` - Frequency in which these events will be sent to IoT Core (e.g. `2s` which means every 2 sec.)
*

```shell
bin/eventmaker --project=${GCP_PROJECT} --region=us-central1 --registry=automodel-reg \
		--device=automodel-device-1 --ca=root-ca.pem --key=device1-private.pem \
		--src=automodel-client --freq=2s --metric=utilization --range=0.01-2.00
```

After few lines of configuration output, you should see `eventmaker` posting to IOT Core

```shell
2019/05/12 16:38:39 Publishing: {"source_id":"comp-client","event_id":"eid-4d29eab6-a11d-4313-a514-19750f339c3c","event_ts":"2019-05-12T23:38:39.352486Z","label":"comp-stats","mem_used":45.30436197916667,"cpu_used":20.5,"load_1":3.45,"load_5":2.84,"load_15":2.6,"random_metric":1.086788711467383}
```

The JSON payload in each one of these events looks something like this:

```json
{
  "source_id":"comp-client",
  "event_id":"eid-4d29eab6-a11d-4313-a514-19750f339c3c",
  "event_ts":"2019-05-12T23:38:39.352486Z",
  "label":"comp-stats",
  "mem_used":45.30436197916667,
  "cpu_used":20.5,
  "load_1":3.45,
  "load_5":2.84,
  "load_15":2.6,
  "random_metric":1.086788711467383
}
```

## Model

### Create Model

In BigQuery query window run

```sql
#standardSQL
CREATE OR REPLACE MODEL automodel.utilization_model
OPTIONS
  (model_type='linear_reg', input_label_cols=['load_15']) AS
SELECT
  label,
  cpu_used,
  mem_used,
  load_1,
  load_5,
  load_15,
  random_metric,
  case when load_1 > load_5 then 1 else 0 end as load_increasing
FROM automodel.event
WHERE RAND() < 0.05
```

results in

```shell
This statement created a new model named automodel.friction_model
```


## Evaluate model

BigQuery model evaluation provides insight into the quality of the model. First we are going to create a table to store the model evaluation data

```sql
CREATE OR REPLACE TABLE automodel.utilization_model_eval (
  eval_ts TIMESTAMP NOT NULL,
  mean_absolute_error FLOAT64 NOT NULL,
  mean_squared_error FLOAT64 NOT NULL,
  mean_squared_log_error FLOAT64 NOT NULL,
  median_absolute_error FLOAT64 NOT NULL,
  r2_score FLOAT64 NOT NULL,
  explained_variance FLOAT64 NOT NULL
)
```

Then we can crate BigQuery Scheduled job


```sql
#standardSQL
INSERT automodel.utilization_model_eval (
   eval_ts,
   mean_absolute_error,
   mean_squared_error,
   mean_squared_log_error,
   median_absolute_error,
   r2_score,
   explained_variance
) WITH T AS (
  SELECT * FROM ML.EVALUATE(MODEL automodel.utilization_model,(
        SELECT
          label,
          cpu_used,
          mem_used,
          load_1,
          load_5,
          load_15,
          random_metric,
          case when load_1 > load_5 then 1 else 0 end as load_increasing
        FROM automodel.event
  ))
)
SELECT
  CURRENT_TIMESTAMP(),
  mean_absolute_error,
  mean_squared_error,
  mean_squared_log_error,
  median_absolute_error,
  r2_score,
  explained_variance
FROM T
```

results in

```shell
mean_absolute_error	 mean_squared_error	 mean_squared_log_error	 median_absolute_error	r2_score            explained_variance
3.2502161606238453   227.0738450661901   0.008387276788977339    0.12880176496196327    0.9990422574648288  0.999079865551752
```

> The R2 score is a statistical measure that determines if the linear regression predictions approximate the actual data. 0 indicates that the model explains none of the variability of the response data around the mean. 1 indicates that the model explains all the variability of the response data around the mean.

# Use your model to predict utilization


```shell
bin/eventmaker --project=${GCP_PROJECT} --region=us-central1 --registry=automodel-reg \
		--device=automodel-device-1 --ca=root-ca.pem --key=device1-private.pem \
		--src=automodel-client --freq=2s --metric=utilization --range=0.01-100.00
```


```sql
#standardSQL
SELECT
  label,
  MIN(predicted_load_15) as min_predicted_load,
  MAX(predicted_load_15) as max_predicted_load
FROM
  ML.PREDICT(MODEL automodel.utilization_model, (
    SELECT
      label,
      cpu_used,
      mem_used,
      load_1,
      load_5,
      load_15,
      random_metric,
      case when load_1 > load_5 then 1 else 0 end as load_increasing
    FROM automodel.event
  ))
GROUP BY label
```


# Cleanup

To delete all the resources created on GCP during the `event` portion of this demo (topic, registry, and devices) run:

```shell
make cleanup
```