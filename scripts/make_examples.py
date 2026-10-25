#!/usr/bin/env python3
"""Writes the Examples collection: well-known sample schemas as .joinery files in Joinery/Examples.

Tables that reference nothing go in the first column, and each table goes one column right of the deepest table it
references, so wires mostly run right to left. Within a column, tables are ordered by where the tables they reference
sit, to keep wires from crossing. IDs are derived from names, so regenerating changes nothing that didn't change.

Usage: python3 scripts/make_examples.py
"""
import json
import os
import uuid

NAMESPACE = uuid.UUID("6f1c3f9e-2a4b-4c8e-9d7a-1b2c3d4e5f60")
COLORS = ["blue", "orange", "green", "purple", "pink", "teal", "indigo", "red", "yellow", "mint", "cyan", "brown"]
# Matches Metrics: header 24, rows 22, tables 236 wide.
HEADER, ROW, WIDTH = 24, 22, 236
COLUMN_GAP, ROW_GAP = 130, 44


def column(spec):
    """'name type' with optional flags: pk, ? (nullable), and '-> table.column' for a foreign key."""
    words = spec.split()
    name, kind = words[0], words[1]
    nullable = kind.endswith("?")
    reference = words[words.index("->") + 1] if "->" in words else None
    return {"name": name, "type": kind.rstrip("?"), "isNullable": nullable, "isPrimaryKey": "pk" in words, "reference": reference}


def build(title, tables):
    specs = {name: [column(c) for c in columns] for name, columns in tables.items()}

    # Depth: one more than the deepest table referenced (cycles and self-references count as nothing).
    depth = {}

    def depth_of(name, path=()):
        if name in depth:
            return depth[name]
        refs = {c["reference"].split(".")[0] for c in specs[name] if c["reference"]} - {name} - set(path)
        d = 1 + max((depth_of(r, path + (name,)) for r in refs), default=-1)
        depth[name] = d
        return d

    for name in specs:
        depth_of(name)

    columns = {}
    for name in specs:
        columns.setdefault(depth[name], []).append(name)
    middle = {}
    position = {}
    x = 0
    for d in sorted(columns):
        names = columns[d]

        def anchor(name):
            refs = [middle[r] for r in {c["reference"].split(".")[0] for c in specs[name] if c["reference"]} if r in middle]
            return sum(refs) / len(refs) if refs else 0

        names.sort(key=lambda n: (anchor(n), n))
        y = 0
        for name in names:
            height = HEADER + ROW * len(specs[name])
            position[name] = [x, y]
            middle[name] = y + height / 2
            y += height + ROW_GAP
        x += WIDTH + COLUMN_GAP
    # Center each column on the tallest.
    tallest = max(max(position[n][1] + HEADER + ROW * len(specs[n]) for n in names) for names in columns.values())
    for names in columns.values():
        bottom = max(position[n][1] + HEADER + ROW * len(specs[n]) for n in names)
        for n in names:
            position[n][1] += (tallest - bottom) / 2

    def uid(*parts):
        return str(uuid.uuid5(NAMESPACE, "/".join((title,) + parts))).upper()

    schema = {"tables": [], "relationships": [], "zipTies": []}
    for index, (name, cols) in enumerate(specs.items()):
        schema["tables"].append({
            "id": uid(name), "name": name, "position": position[name], "color": COLORS[index % len(COLORS)],
            "columns": [{"id": uid(name, c["name"]), "name": c["name"], "type": c["type"],
                         "isPrimaryKey": c["isPrimaryKey"], "isNullable": c["isNullable"]} for c in cols],
        })
        for c in cols:
            if c["reference"]:
                table, target = c["reference"].split(".")
                assert table in specs and any(t["name"] == target for t in specs[table]), f"{title}: {c['reference']}"
                schema["relationships"].append({"id": uid(name, c["name"], "fk"), "from": uid(name, c["name"]),
                                                "to": uid(table, target), "zipTies": []})
    return schema


EXAMPLES = {
    # The Chinook digital media store (Luis Rocha), a stand-in for Northwind on many databases.
    "Chinook": {
        "Artist": ["ArtistId integer pk", "Name varchar?"],
        "Album": ["AlbumId integer pk", "Title varchar", "ArtistId integer -> Artist.ArtistId"],
        "MediaType": ["MediaTypeId integer pk", "Name varchar?"],
        "Genre": ["GenreId integer pk", "Name varchar?"],
        "Track": ["TrackId integer pk", "Name varchar", "AlbumId integer? -> Album.AlbumId",
                  "MediaTypeId integer -> MediaType.MediaTypeId", "GenreId integer? -> Genre.GenreId", "Composer varchar?",
                  "Milliseconds integer", "Bytes integer?", "UnitPrice numeric"],
        "Playlist": ["PlaylistId integer pk", "Name varchar?"],
        "PlaylistTrack": ["PlaylistId integer pk -> Playlist.PlaylistId", "TrackId integer pk -> Track.TrackId"],
        "Employee": ["EmployeeId integer pk", "LastName varchar", "FirstName varchar", "Title varchar?",
                     "ReportsTo integer? -> Employee.EmployeeId", "BirthDate timestamp?", "HireDate timestamp?",
                     "City varchar?", "Country varchar?", "Email varchar?"],
        "Customer": ["CustomerId integer pk", "FirstName varchar", "LastName varchar", "Company varchar?",
                     "City varchar?", "Country varchar?", "Email varchar", "SupportRepId integer? -> Employee.EmployeeId"],
        "Invoice": ["InvoiceId integer pk", "CustomerId integer -> Customer.CustomerId", "InvoiceDate timestamp",
                    "BillingCity varchar?", "BillingCountry varchar?", "Total numeric"],
        "InvoiceLine": ["InvoiceLineId integer pk", "InvoiceId integer -> Invoice.InvoiceId",
                        "TrackId integer -> Track.TrackId", "UnitPrice numeric", "Quantity integer"],
    },
    # Microsoft's Northwind Traders.
    "Northwind": {
        "Categories": ["CategoryID integer pk", "CategoryName varchar", "Description text?", "Picture bytea?"],
        "Suppliers": ["SupplierID integer pk", "CompanyName varchar", "ContactName varchar?", "City varchar?",
                      "Country varchar?", "Phone varchar?", "HomePage text?"],
        "Products": ["ProductID integer pk", "ProductName varchar", "SupplierID integer? -> Suppliers.SupplierID",
                     "CategoryID integer? -> Categories.CategoryID", "QuantityPerUnit varchar?", "UnitPrice numeric?",
                     "UnitsInStock integer?", "UnitsOnOrder integer?", "ReorderLevel integer?", "Discontinued boolean"],
        "Customers": ["CustomerID varchar pk", "CompanyName varchar", "ContactName varchar?", "City varchar?",
                      "Country varchar?", "Phone varchar?"],
        "Region": ["RegionID integer pk", "RegionDescription varchar"],
        "Territories": ["TerritoryID varchar pk", "TerritoryDescription varchar", "RegionID integer -> Region.RegionID"],
        "Employees": ["EmployeeID integer pk", "LastName varchar", "FirstName varchar", "Title varchar?",
                      "BirthDate date?", "HireDate date?", "City varchar?", "Country varchar?",
                      "ReportsTo integer? -> Employees.EmployeeID"],
        "EmployeeTerritories": ["EmployeeID integer pk -> Employees.EmployeeID",
                                "TerritoryID varchar pk -> Territories.TerritoryID"],
        "Shippers": ["ShipperID integer pk", "CompanyName varchar", "Phone varchar?"],
        "Orders": ["OrderID integer pk", "CustomerID varchar? -> Customers.CustomerID",
                   "EmployeeID integer? -> Employees.EmployeeID", "OrderDate date?", "RequiredDate date?",
                   "ShippedDate date?", "ShipVia integer? -> Shippers.ShipperID", "Freight numeric?", "ShipCity varchar?",
                   "ShipCountry varchar?"],
        "OrderDetails": ["OrderID integer pk -> Orders.OrderID", "ProductID integer pk -> Products.ProductID",
                         "UnitPrice numeric", "Quantity integer", "Discount numeric"],
    },
    # MySQL's Sakila DVD rental store (Pagila on Postgres).
    "Sakila": {
        "country": ["country_id integer pk", "country varchar", "last_update timestamp"],
        "city": ["city_id integer pk", "city varchar", "country_id integer -> country.country_id", "last_update timestamp"],
        "address": ["address_id integer pk", "address varchar", "address2 varchar?", "district varchar",
                    "city_id integer -> city.city_id", "postal_code varchar?", "phone varchar", "last_update timestamp"],
        "language": ["language_id integer pk", "name varchar", "last_update timestamp"],
        "category": ["category_id integer pk", "name varchar", "last_update timestamp"],
        "actor": ["actor_id integer pk", "first_name varchar", "last_name varchar", "last_update timestamp"],
        "film": ["film_id integer pk", "title varchar", "description text?", "release_year integer?",
                 "language_id integer -> language.language_id",
                 "original_language_id integer? -> language.language_id", "rental_duration integer",
                 "rental_rate numeric", "length integer?", "replacement_cost numeric", "rating varchar?",
                 "last_update timestamp"],
        "film_actor": ["actor_id integer pk -> actor.actor_id", "film_id integer pk -> film.film_id",
                       "last_update timestamp"],
        "film_category": ["film_id integer pk -> film.film_id", "category_id integer pk -> category.category_id",
                          "last_update timestamp"],
        "staff": ["staff_id integer pk", "first_name varchar", "last_name varchar",
                  "address_id integer -> address.address_id", "email varchar?", "store_id integer -> store.store_id",
                  "active boolean", "username varchar", "last_update timestamp"],
        "store": ["store_id integer pk", "manager_staff_id integer -> staff.staff_id",
                  "address_id integer -> address.address_id", "last_update timestamp"],
        "inventory": ["inventory_id integer pk", "film_id integer -> film.film_id", "store_id integer -> store.store_id",
                      "last_update timestamp"],
        "customer": ["customer_id integer pk", "store_id integer -> store.store_id", "first_name varchar",
                     "last_name varchar", "email varchar?", "address_id integer -> address.address_id",
                     "active boolean", "create_date date", "last_update timestamp"],
        "rental": ["rental_id integer pk", "rental_date timestamp", "inventory_id integer -> inventory.inventory_id",
                   "customer_id integer -> customer.customer_id", "return_date timestamp?",
                   "staff_id integer -> staff.staff_id", "last_update timestamp"],
        "payment": ["payment_id integer pk", "customer_id integer -> customer.customer_id",
                    "staff_id integer -> staff.staff_id", "rental_id integer? -> rental.rental_id", "amount numeric",
                    "payment_date timestamp"],
    },
    # The Stack Exchange data dump.
    "Stack Overflow": {
        "Users": ["Id integer pk", "Reputation integer", "CreationDate timestamp", "DisplayName varchar",
                  "LastAccessDate timestamp", "Location varchar?", "AboutMe text?", "Views integer", "UpVotes integer",
                  "DownVotes integer"],
        "PostTypes": ["Id integer pk", "Type varchar"],
        "Posts": ["Id integer pk", "PostTypeId integer -> PostTypes.Id", "AcceptedAnswerId integer? -> Posts.Id",
                  "ParentId integer? -> Posts.Id", "CreationDate timestamp", "Score integer", "ViewCount integer?",
                  "Body text", "OwnerUserId integer? -> Users.Id", "LastEditorUserId integer? -> Users.Id",
                  "Title varchar?", "Tags varchar?", "AnswerCount integer?", "CommentCount integer",
                  "ClosedDate timestamp?"],
        "Comments": ["Id integer pk", "PostId integer -> Posts.Id", "Score integer", "Text text",
                     "CreationDate timestamp", "UserId integer? -> Users.Id"],
        "VoteTypes": ["Id integer pk", "Name varchar"],
        "Votes": ["Id integer pk", "PostId integer -> Posts.Id", "VoteTypeId integer -> VoteTypes.Id",
                  "UserId integer? -> Users.Id", "CreationDate timestamp", "BountyAmount integer?"],
        "Badges": ["Id integer pk", "UserId integer -> Users.Id", "Name varchar", "Date timestamp", "Class integer",
                   "TagBased boolean"],
        "Tags": ["Id integer pk", "TagName varchar", "Count integer", "ExcerptPostId integer? -> Posts.Id",
                 "WikiPostId integer? -> Posts.Id"],
        "PostLinks": ["Id integer pk", "CreationDate timestamp", "PostId integer -> Posts.Id",
                      "RelatedPostId integer -> Posts.Id", "LinkTypeId integer"],
    },
    # A small online shop, the app's own sample.
    "Storefront": {
        "users": ["id uuid pk", "email text", "name text", "created_at timestamp"],
        "addresses": ["id uuid pk", "user_id uuid -> users.id", "line1 text", "city text", "postal_code varchar"],
        "categories": ["id uuid pk", "parent_id uuid? -> categories.id", "name text"],
        "products": ["id uuid pk", "category_id uuid -> categories.id", "name text", "price numeric",
                     "in_stock boolean", "attributes json?"],
        "orders": ["id uuid pk", "user_id uuid -> users.id", "shipping_address_id uuid -> addresses.id", "status text",
                   "total numeric", "placed_at timestamp"],
        "order_items": ["id uuid pk", "order_id uuid -> orders.id", "product_id uuid -> products.id",
                        "quantity integer", "unit_price numeric"],
        "payments": ["id uuid pk", "order_id uuid -> orders.id", "amount numeric", "provider text",
                     "paid_at timestamp?"],
        "reviews": ["id uuid pk", "product_id uuid -> products.id", "user_id uuid -> users.id", "rating integer",
                    "body text?", "is_verified boolean"],
    },
}

if __name__ == "__main__":
    folder = os.path.join(os.path.dirname(__file__), "..", "Joinery", "Examples")
    os.makedirs(folder, exist_ok=True)
    for title, tables in EXAMPLES.items():
        with open(os.path.join(folder, f"{title}.joinery"), "w") as file:
            json.dump(build(title, tables), file, indent=2, sort_keys=True)
        print(f"{title}: {len(tables)} tables")
