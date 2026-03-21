from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy import create_engine, Column, Integer, String, Boolean, ForeignKey, Text
from sqlalchemy.orm import declarative_base, sessionmaker, Session

# 1. Database Setup
SQLALCHEMY_DATABASE_URL = "sqlite:///./opensigweave.db"
# check_same_thread is needed for SQLite in FastAPI
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# 2. Database Models (The Schema we discussed)
class Domain(Base):
    __tablename__ = "domains"

    id = Column(Integer, primary_key=True, index=True)
    domain_name = Column(String, unique=True, index=True, nullable=False)
    html_template = Column(Text, nullable=True)
    plain_template = Column(Text, nullable=True)
    is_active = Column(Boolean, default=True)

class UserOverride(Base):
    __tablename__ = "user_overrides"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True, nullable=False)
    domain_id = Column(Integer, ForeignKey("domains.id"), nullable=False)
    html_override = Column(Text, nullable=True)
    plain_override = Column(Text, nullable=True)
    is_locked = Column(Boolean, default=False)

# Create the tables in the database
Base.metadata.create_all(bind=engine)

# 3. FastAPI App Initialization
app = FastAPI(title="OpenSigWeave API", version="0.1.0")

# Dependency to get the database session
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# 4. Basic Endpoints
@app.get("/")
def read_root():
    return {"message": "OpenSigWeave Backend is running!"}

@app.get("/health")
def health_check():
    return {"status": "healthy", "database": "connected"}
