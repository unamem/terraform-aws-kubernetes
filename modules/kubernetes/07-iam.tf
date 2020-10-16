resource "aws_iam_role_policy_attachment" "ssm_policy_att" {
  count      = var.enable_ssm_access_to_nodes ? 1 : 0
  role       = aws_iam_role.k8s_assume_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}