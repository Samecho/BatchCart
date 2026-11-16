import { test, expect } from "@playwright/test"
import { readFileSync } from "node:fs"

test("fix a CSV record, confirm two drafts, then download the results", async ({ page }) => {
  const unique = Date.now().toString(36)
  const csv = readFileSync("test/fixtures/files/mixed.csv", "utf8")
    .replaceAll("@example.test", `+${unique}@example.test`)
  await page.goto("/")
  await page.getByRole("button", { name: "Open demo shop" }).click()
  await expect(page.getByRole("heading", { name: "Order batches" })).toBeVisible()

  await page.getByLabel("Order CSV").setInputFiles({
    name: `fundraiser-${unique}.csv`, mimeType: "text/csv", buffer: Buffer.from(csv),
  })
  await page.getByRole("button", { name: "Upload and validate" }).click()
  await expect(page.getByText("Use a whole number from 1 to 9999.")).toBeVisible()
  await expect(page.getByRole("button", { name: /Create .* draft order/ })).toHaveCount(0)
  await expect(page.getByText("2 × Camp mug")).toBeVisible()
  await page.getByRole("button", { name: "4", exact: true }).click()
  await page.getByLabel("Quantity").fill("1")
  await page.getByRole("button", { name: "Save and validate" }).click()
  await expect(page.getByText(/Version 2 · 3 CSV records/)).toBeVisible()
  await expect(page.getByRole("link", { name: "Previous version" })).toBeVisible()

  const confirm = page.getByRole("button", { name: "Create 2 draft orders" })
  await expect(confirm).toBeEnabled()
  await page.getByRole("heading", { name: "Order preview" }).scrollIntoViewIfNeeded()
  if (process.env.BATCHCART_SCREENSHOTS) await page.screenshot({ path: "test-results/preview.png", fullPage: true })
  await confirm.click()
  await expect(page.getByText("2 of 2 with a result · 2 created")).toBeVisible()
  await expect(page.getByText("Finished", { exact: true })).toBeVisible()
  const [download] = await Promise.all([
    page.waitForEvent("download"),
    page.getByRole("link", { name: "Export results" }).click(),
  ])
  const result = readFileSync((await download.path())!, "utf8")
  expect(result).toContain("GIFT-101,GIFT-MUG,2,succeeded,gid://batchcart-demo/DraftOrder/")
  expect(result).toContain("GIFT-102,GIFT-TEE,1,succeeded,gid://batchcart-demo/DraftOrder/")
  if (process.env.BATCHCART_SCREENSHOTS) {
    await page.screenshot({ path: "test-results/results.png", fullPage: true })
    await page.setViewportSize({ width: 1120, height: 700 })
    await page.screenshot({ path: "test-results/results-compact.png", fullPage: true })
    await page.setViewportSize({ width: 390, height: 844 })
    await page.screenshot({ path: "test-results/results-mobile.png", fullPage: true })
    expect(await page.evaluate(() => document.body.scrollWidth)).toBe(390)
    expect(await page.getByRole("table", { name: /Orders/ }).evaluate((table) => table.scrollWidth)).toBeLessThan(390)
    await expect(page.getByText("Created", { exact: true }).first()).toBeInViewport()
  }
})

test("a request without the Rails CSRF token cannot open the demo shop", async ({ request }) => {
  const response = await request.post("/auth/demo")
  expect(response.status()).toBe(422)
})
