---
name: aws-openshift-discovery
description: >-
  Check an AWS account for OpenShift clusters (ROSA, HyperShift, or
  self-managed/IPI) and extract their access info: API server URL, console
  URL, kubeadmin password, node inventory, and health. Use when given AWS
  credentials and asked to log into an AWS account, check for an OpenShift
  cluster, or report cluster access details.
disable-model-invocation: true
---

# AWS OpenShift Discovery

## Step 1: Configure AWS CLI credentials

Prefer inline env vars for the single command rather than writing a persistent
profile, so secrets aren't left in `~/.aws/credentials`:

```bash
AWS_ACCESS_KEY_ID=<key_id> \
AWS_SECRET_ACCESS_KEY=<secret> \
AWS_DEFAULT_REGION=us-east-1 \
aws sts get-caller-identity
```

If exporting for a multi-command session instead, note that raw credential
exports may require explicit user approval under auto-review — that's
expected when the user supplied the credentials for this exact purpose.

## Step 2: Find which region(s) have resources

There's no single global API for "all resources everywhere." Loop over common
regions checking EC2 instances and CloudFormation stacks (fast and cheap):

```bash
for r in us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-central-1 \
         ap-southeast-1 ap-southeast-2 ap-northeast-1; do
  insts=$(aws ec2 describe-instances --region "$r" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)
  stacks=$(aws cloudformation list-stacks --region "$r" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
    --query 'length(StackSummaries)' --output text 2>/dev/null)
  echo "region=$r instances=$insts stacks=$stacks"
done
```

Any region with a non-zero instance count is worth inspecting further.

## Step 3: Identify the cluster type

**ROSA / HyperShift (managed control plane):**
```bash
rosa list clusters                      # if rosa CLI is installed
aws cloudformation list-stacks --query "StackSummaries[?contains(StackName,'rosa') || contains(StackName,'hypershift')]"
```

**Self-managed OpenShift (IPI/UPI on EC2)** — this is the common case for
demo/sandbox environments. Confirm via EC2 instance tags:
```bash
aws ec2 describe-instances --region <region> \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags]' --output json
```
Look for tags like `kubernetes.io/cluster/<infra-id>: owned`,
`sigs.k8s.io/cluster-api-provider-aws/role: control-plane`, and
`MachineName: openshift-cluster-api-guests/<infra-id>-master-N`. The
`<infra-id>` (e.g. `rhoai-tokyo-lq9zg`) is `<cluster-name>-<random5>`.

## Step 4: Get the base domain and endpoints

```bash
aws route53 list-hosted-zones --query 'HostedZones[].[Name,Id]' --output table
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> \
  --query 'ResourceRecordSets[].[Name,Type]' --output table
```
A hosted zone named `<cluster-name>.<base-domain>` with `api.*`, `api-int.*`,
and `*.apps.*` A records confirms an OpenShift cluster. Standard endpoints:
- API: `https://api.<cluster-name>.<base-domain>:6443`
- Console: `https://console-openshift-console.apps.<cluster-name>.<base-domain>`
- OAuth: `https://oauth-openshift.apps.<cluster-name>.<base-domain>`

## Step 5: Check cluster health

```bash
curl -sk -m 8 https://api.<...>:6443/version          # API reachability
curl -sk -m 10 -v https://console-openshift-console.apps.<...>/   # console reachability

# Load balancers and target health reveal API vs. ingress router status
aws elbv2 describe-load-balancers --region <region> --query 'LoadBalancers[].[LoadBalancerName,DNSName,Type]'
aws elbv2 describe-target-groups --region <region> --query 'TargetGroups[].TargetGroupArn' --output text \
  | xargs -n1 -I{} aws elbv2 describe-target-health --region <region> --target-group-arn {}
aws elb describe-load-balancers --region <region>       # classic ELB = router/ingress
aws elb describe-instance-health --region <region> --load-balancer-name <name>
```
API server healthy but router/ingress `OutOfService` is a common partial-outage
pattern (API reachable, console/apps routes down).

## Step 6: Look for stored credentials (often not present)

Self-managed clusters' `kubeadmin` password is generated locally by
`openshift-install` and is usually **not** persisted in AWS — check anyway:

```bash
aws secretsmanager list-secrets --region <region> --query 'SecretList[].Name'
aws ssm describe-parameters --region <region> --query 'Parameters[].Name'
aws cloudformation describe-stacks --region <region> --stack-name <name> \
  --query 'Stacks[0].Outputs'   # sometimes holds admin IAM creds, rarely OCP creds
aws ec2 describe-key-pairs --region <region>   # SSH key names only (no private key material)
```
If nothing turns up, say so explicitly rather than guessing — the password
likely lives in a lab guide, provisioning email, or secrets vault outside AWS.
Do not attempt `oc login` with guessed/placeholder credentials.

## Step 7: Report

Summarize: cluster name/infra-id, region, node inventory (role/instance
type/state), API/console/oauth URLs, health status per endpoint, where
credentials were (or weren't) found, and the AWS IAM console access used to
discover all this.
